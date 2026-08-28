"""Game browsing and management API."""

from __future__ import annotations

from datetime import datetime
import re
from uuid import uuid4

import httpx
from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field
from sqlalchemy import select, or_, func
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import joinedload, selectinload

from api.auth import get_current_user, require_admin
from config import load_config
from database import get_session
from models.user import User
from models.game import Company, Game, GameVersion, GameTag, Platform
from models.ignore_list import IgnoreList
from models.tag import Tag
from schemas.common import MessageResponse
from schemas.game import GameDetail, GameSummary
from services.importer import cleanup_empty_companies
from services.scraper.base import ScrapedTag, ScraperResult
from services.scraper.orchestrator import _apply_result

router = APIRouter(prefix="/api/games", tags=["games"])


_ENTRY_SOURCES = {"library", "manual", "metadata"}
_CREATE_ENTRY_SOURCES = {"manual", "metadata"}
_SOURCE_ID_FIELDS = {
    "vndb_kana": "vndb_id",
    "vndb": "vndb_id",
    "bangumi": "bangumi_id",
    "steam": "steam_id",
    "hikarinagi": "hikarinagi_id",
}


def _entry_source(game: Game) -> str:
    source = (getattr(game, "entry_source", None) or "library").strip()
    return source if source in _ENTRY_SOURCES else "library"


def _is_virtual_game_path(path: str | None) -> bool:
    value = (path or "").strip()
    return value.startswith(("manual://", "metadata://", "/virtual/"))


def _should_ignore_game_path(game: Game) -> bool:
    return (
        _entry_source(game) == "library"
        and bool(game.folder_path)
        and not _is_virtual_game_path(game.folder_path)
    )


async def _add_ignore_path_once(session: AsyncSession, game: Game) -> None:
    if not _should_ignore_game_path(game):
        return
    existing = await session.execute(
        select(IgnoreList).where(IgnoreList.path == game.folder_path)
    )
    if existing.scalar_one_or_none() is None:
        session.add(IgnoreList(path=game.folder_path))


def _game_to_summary(game: Game) -> GameSummary:
    """Convert a Game ORM object to a GameSummary schema."""
    platforms = list({v.platform.value for v in game.versions}) if game.versions else []
    tag_names = [gt.tag.name for gt in game.tags] if game.tags else []
    return GameSummary(
        id=game.id,
        name=game.name,
        company_name=game.company.name if game.company else None,
        developer=game.developer,
        folder_path=game.folder_path,
        entry_source=_entry_source(game),
        cover_path=game.cover_path,
        is_nsfw=bool(game.is_nsfw),
        platform_summary=", ".join(platforms),
        tag_names=tag_names,
        imported_at=game.imported_at,
        length=game.length or 0,
        length_minutes=game.length_minutes or 0,
    )


@router.get("", response_model=list[GameSummary])
async def list_games(
    page: int = Query(default=1, ge=1),
    page_size: int = Query(default=50, ge=1, le=200),
    tag: str | None = Query(default=None),
    platform: str | None = Query(default=None),
    root_id: int | None = Query(default=None),
    developer: str | None = Query(default=None),
    has_cover: bool | None = Query(default=None),
    sort: str = Query(default="imported"),
    session: AsyncSession = Depends(get_session),
    user: User = Depends(get_current_user),
):
    """List games with optional filters and sorting.

    Filters: tag, platform, root_id, developer, has_cover
    Sort options: imported (default), name, name_desc, company, developer, developer_desc
    """
    query = (
        select(Game)
        .where(Game.is_deleted == False)
        .options(
            joinedload(Game.company),
            selectinload(Game.versions),
            selectinload(Game.tags).joinedload(GameTag.tag),
        )
    )

    if root_id is not None:
        query = query.where(Game.root_id == root_id)
    if platform:
        query = query.where(
            Game.versions.any(GameVersion.platform == platform)
        )
    if developer:
        query = query.where(Game.developer.ilike(f"%{developer}%"))
    if has_cover is not None:
        if has_cover:
            query = query.where(Game.cover_path.isnot(None)).where(Game.cover_path != "")
        else:
            query = query.where(
                (Game.cover_path.is_(None)) | (Game.cover_path == "")
            )

    # Filter by tag name
    if tag:
        query = query.where(
            Game.tags.any(
                GameTag.tag.has(Tag.name == tag)
            )
        )

    # Ordering
    if sort == "company":
        query = query.outerjoin(Game.company).order_by(Company.name.asc().nulls_last(), Game.name.asc())
    elif sort == "developer":
        query = query.order_by(Game.developer.asc().nulls_last(), Game.name.asc())
    elif sort == "developer_desc":
        query = query.order_by(Game.developer.desc().nulls_last(), Game.name.asc())
    elif sort == "name":
        query = query.order_by(Game.name.asc(), Game.imported_at.desc())
    elif sort == "name_desc":
        query = query.order_by(Game.name.desc())
    else:
        query = query.order_by(Game.imported_at.desc())

    query = query.offset((page - 1) * page_size).limit(page_size)

    result = await session.execute(query)
    games = result.unique().scalars().all()
    return [_game_to_summary(g) for g in games]


@router.get("/search", response_model=list[GameSummary])
async def search_games(
    q: str = Query(min_length=1),
    page: int = Query(default=1, ge=1),
    page_size: int = Query(default=50, ge=1, le=200),
    tag: str | None = Query(default=None),
    platform: str | None = Query(default=None),
    root_id: int | None = Query(default=None),
    session: AsyncSession = Depends(get_session),
    user: User = Depends(get_current_user),
):
    """Search games by name, folder path, or tag."""
    query = (
        select(Game)
        .where(Game.is_deleted == False)
        .options(
            joinedload(Game.company),
            selectinload(Game.versions),
            selectinload(Game.tags).joinedload(GameTag.tag),
        )
    )

    # Full-text-ish search across name, folder_path, and tag names
    search_term = f"%{q}%"
    query = query.where(
        or_(
            Game.name.ilike(search_term),
            Game.folder_path.ilike(search_term),
            Game.tags.any(
                GameTag.tag.has(Tag.name.ilike(search_term))
            ),
        )
    )

    if root_id is not None:
        query = query.where(Game.root_id == root_id)
    if platform:
        query = query.where(
            Game.versions.any(GameVersion.platform == platform)
        )
    if tag:
        query = query.where(
            Game.tags.any(GameTag.tag.has(Tag.name == tag))
        )

    query = query.order_by(Game.imported_at.desc())
    query = query.offset((page - 1) * page_size).limit(page_size)

    result = await session.execute(query)
    games = result.unique().scalars().all()
    return [_game_to_summary(g) for g in games]


@router.get("/{game_id}", response_model=GameDetail)
async def get_game(
    game_id: int,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(get_current_user),
):
    """Get a single game with full details including versions and tags."""
    result = await session.execute(
        select(Game)
        .where(Game.id == game_id)
        .options(
            joinedload(Game.company),
            selectinload(Game.versions),
            selectinload(Game.tags).joinedload(GameTag.tag),
        )
    )
    game = result.unique().scalar_one_or_none()
    if game is None:
        raise HTTPException(status_code=404, detail="Game not found")

    platforms = list({v.platform.value for v in game.versions})
    return GameDetail(
        id=game.id,
        name=game.name,
        company_name=game.company.name if game.company else None,
        root_id=game.root_id,
        folder_path=game.folder_path,
        entry_source=_entry_source(game),
        cover_path=game.cover_path,
        bg_path=game.bg_path,
        is_nsfw=bool(game.is_nsfw),
        developer=game.developer,
        description=game.description,
        release_date=game.release_date,
        vndb_id=game.vndb_id,
        steam_id=game.steam_id,
        bangumi_id=game.bangumi_id,
        hikarinagi_id=game.hikarinagi_id,
        length=game.length or 0,
        length_minutes=game.length_minutes or 0,
        is_deleted=game.is_deleted,
        imported_at=game.imported_at,
        updated_at=game.updated_at,
        versions=[
            {
                "id": v.id,
                "platform": v.platform.value,
                "filename": v.filename,
                "file_path": v.file_path,
                "file_size": v.file_size,
                "source_type": v.source_type,
                "source_id": v.source_id,
                "source_path": v.source_path,
                "extract_password": v.extract_password,
                "checksum_algo": v.checksum_algo,
                "checksum": v.checksum,
            }
            for v in game.versions
        ],
        tags=[
            {
                "id": gt.tag.id,
                "name": gt.tag.name,
                "color": gt.tag.color,
                "created_at": gt.tag.created_at,
                "source": gt.source,
                "weight": gt.weight or 0.0,
                "rating": gt.weight or 0.0,
                "is_spoiler": bool(gt.is_spoiler),
                "spoiler": bool(gt.is_spoiler),
            }
            for gt in sorted(
                game.tags,
                key=lambda gt: (
                    0 if (gt.source or "") == "user" else 1,
                    -(gt.weight or 0.0),
                    gt.tag.name.lower(),
                ),
            )
        ],
    )


@router.delete("/{game_id}", response_model=MessageResponse)
async def delete_game(
    game_id: int,
    user: User = Depends(require_admin),
    session: AsyncSession = Depends(get_session),
):
    """Soft-delete a game (admin only)."""
    result = await session.execute(
        select(Game).where(Game.id == game_id)
    )
    game = result.scalar_one_or_none()
    if game is None:
        raise HTTPException(status_code=404, detail="Game not found")

    # Soft delete
    game.is_deleted = True
    game.updated_at = datetime.utcnow()

    await _add_ignore_path_once(session, game)

    await cleanup_empty_companies(session)
    await session.commit()
    return MessageResponse(message=f"Game '{game.name}' removed")


class BatchDeleteRequest(BaseModel):
    game_ids: list[int]

@router.post("/batch-delete", response_model=MessageResponse)
async def batch_delete_games(
    body: BatchDeleteRequest,
    user: User = Depends(require_admin),
    session: AsyncSession = Depends(get_session),
):
    """Soft-delete multiple games at once (admin only)."""
    if not body.game_ids:
        return MessageResponse(message="没有要删除的游戏")
    # Single query for all games
    result = await session.execute(
        select(Game).where(Game.id.in_(body.game_ids)))
    games = result.scalars().all()
    paths = {g.folder_path for g in games if _should_ignore_game_path(g)}
    # Batch check ignore list
    if paths:
        ignored = await session.execute(
            select(IgnoreList.path).where(IgnoreList.path.in_(paths)))
        ignored_paths = {row[0] for row in ignored.all()}
    else:
        ignored_paths = set()
    deleted = 0
    for game in games:
        game.is_deleted = True
        game.updated_at = datetime.utcnow()
        if _should_ignore_game_path(game) and game.folder_path not in ignored_paths:
            session.add(IgnoreList(path=game.folder_path))
            ignored_paths.add(game.folder_path)
        deleted += 1
    await cleanup_empty_companies(session)
    await session.commit()
    return MessageResponse(message=f"已删除 {deleted} 个游戏")


class GameCreateTag(BaseModel):
    name: str
    rating: float = 0.0
    is_spoiler: bool = False


class GameCreate(BaseModel):
    name: str
    entry_source: str | None = None
    source: str | None = None
    source_id: str | None = None
    developer: str | None = None
    description: str | None = None
    release_date: str | None = None
    cover_url: str | None = None
    hero_url: str | None = None
    is_nsfw: bool | None = None
    length: int | None = None
    length_minutes: int | None = None
    tags: list[GameCreateTag] = Field(default_factory=list)


def _clean_create_text(value: str | None, max_length: int | None = None) -> str:
    text = (value or "").strip()
    return text[:max_length] if max_length is not None else text


def _normalize_create_source(body: GameCreate) -> str:
    requested = (body.entry_source or "").strip().lower()
    if requested in _CREATE_ENTRY_SOURCES:
        return requested
    if body.source or body.source_id or body.cover_url or body.hero_url or body.tags:
        return "metadata"
    return "manual"


def _source_id_field(source: str | None) -> str | None:
    return _SOURCE_ID_FIELDS.get((source or "").strip().lower())


def _safe_virtual_path_part(value: str) -> str:
    text = re.sub(r"[^A-Za-z0-9_.-]+", "_", value.strip())
    text = text.strip("._-")
    return text[:160] or "item"


def _virtual_folder_path(entry_source: str, source: str, source_id: str) -> str:
    if entry_source == "metadata" and source and source_id:
        return f"metadata://{_safe_virtual_path_part(source)}/{_safe_virtual_path_part(source_id)}"
    return f"manual://game/{uuid4().hex}"


async def _get_or_create_company(
    session: AsyncSession,
    name: str,
) -> Company | None:
    company_name = _clean_create_text(name, 255)
    if not company_name:
        return None
    result = await session.execute(select(Company).where(Company.name == company_name))
    company = result.scalar_one_or_none()
    if company is None:
        company = Company(name=company_name)
        session.add(company)
        await session.flush()
    return company


async def _apply_create_payload(
    session: AsyncSession,
    game: Game,
    body: GameCreate,
    entry_source: str,
) -> None:
    name = _clean_create_text(body.name, 512)
    source = (body.source or "").strip().lower()
    source_id = _clean_create_text(body.source_id, 64)
    developer = _clean_create_text(body.developer, 512)

    game.name = name
    if _entry_source(game) != "library" or entry_source == "library":
        game.entry_source = entry_source
    if developer:
        game.developer = developer
        company = await _get_or_create_company(session, developer)
        if company is not None:
            game.company_id = company.id
    if body.description is not None:
        game.description = _clean_create_text(body.description, 2000)
    if body.release_date is not None:
        game.release_date = _clean_create_text(body.release_date, 64)
    if body.is_nsfw is not None:
        game.is_nsfw = bool(body.is_nsfw)
    if body.length is not None:
        game.length = max(0, body.length)
    if body.length_minutes is not None:
        game.length_minutes = max(0, body.length_minutes)

    id_field = _source_id_field(source)
    if id_field and source_id:
        setattr(game, id_field, source_id)

    tags = [
        ScrapedTag(
            name=_clean_create_text(tag.name, 128),
            rating=tag.rating,
            is_spoiler=tag.is_spoiler,
        )
        for tag in body.tags
        if _clean_create_text(tag.name)
    ]
    scraper_result = ScraperResult(
        title=name,
        developer=developer,
        description=_clean_create_text(body.description, 2000),
        release_date=_clean_create_text(body.release_date, 64),
        cover_url=_clean_create_text(body.cover_url),
        hero_url=_clean_create_text(body.hero_url),
        source_id=source_id,
        source_name=source,
        length=body.length or 0,
        length_minutes=body.length_minutes or 0,
        is_nsfw=body.is_nsfw,
        tags=tags,
    )

    config = load_config()
    client_kwargs = {"timeout": httpx.Timeout(30.0), "trust_env": False}
    if config.proxy:
        client_kwargs["proxy"] = config.proxy
    async with httpx.AsyncClient(**client_kwargs) as client:
        await _apply_result(
            scraper_result,
            source or entry_source,
            game,
            client,
            config.covers_path,
            session,
            config,
            mode="overwrite",
        )
    game.updated_at = datetime.utcnow()


async def _create_game_from_payload(
    body: GameCreate,
    session: AsyncSession,
) -> tuple[Game, bool]:
    name = _clean_create_text(body.name, 512)
    if not name:
        raise HTTPException(status_code=400, detail="游戏名称不能为空")

    entry_source = _normalize_create_source(body)
    source = (body.source or "").strip().lower()
    source_id = _clean_create_text(body.source_id, 64)
    id_field = _source_id_field(source)
    if source and id_field is None:
        raise HTTPException(status_code=400, detail=f"Unknown source: {source}")

    if id_field and source_id:
        existing = await session.execute(
            select(Game).where(getattr(Game, id_field) == source_id)
        )
        game = existing.scalar_one_or_none()
        if game is not None:
            game.is_deleted = False
            await _apply_create_payload(session, game, body, entry_source)
            await session.commit()
            await session.refresh(game)
            return game, True

    folder_path = _virtual_folder_path(entry_source, source, source_id)
    existing_path = await session.execute(
        select(Game).where(Game.folder_path == folder_path)
    )
    game = existing_path.scalar_one_or_none()
    if game is not None:
        game.is_deleted = False
        await _apply_create_payload(session, game, body, entry_source)
        await session.commit()
        await session.refresh(game)
        return game, True

    game = Game(
        name=name,
        root_id=0,
        folder_path=folder_path,
        entry_source=entry_source,
        is_deleted=False,
        imported_at=datetime.utcnow(),
        updated_at=datetime.utcnow(),
    )
    session.add(game)
    await session.flush()
    await _apply_create_payload(session, game, body, entry_source)
    await session.commit()
    await session.refresh(game)
    return game, False


@router.post("")
async def create_game(
    body: GameCreate,
    user: User = Depends(require_admin),
    session: AsyncSession = Depends(get_session),
):
    """Create a manual or metadata-backed game entry."""
    game, existing = await _create_game_from_payload(body, session)
    return {
        "id": game.id,
        "name": game.name,
        "entry_source": _entry_source(game),
        "existing": existing,
    }


class GameUpdate(BaseModel):
    name: str | None = None
    developer: str | None = None
    description: str | None = None
    release_date: str | None = None
    bg_path: str | None = None
    vndb_id: str | None = None
    steam_id: str | None = None
    bangumi_id: str | None = None
    hikarinagi_id: str | None = None
    is_nsfw: bool | None = None
    tag_names: list[str] | None = None
    tag_source: str | None = None


class VersionUpdate(BaseModel):
    platform: str | None = None
    extract_password: str | None = None


@router.put("/{game_id}")
async def update_game(
    game_id: int,
    body: GameUpdate,
    user: User = Depends(require_admin),
    session: AsyncSession = Depends(get_session),
):
    """Edit game metadata (admin only)."""
    result = await session.execute(select(Game).where(Game.id == game_id))
    game = result.scalar_one_or_none()
    if game is None:
        raise HTTPException(status_code=404, detail="Game not found")

    data = body.model_dump(exclude_unset=True)
    tag_names = data.pop("tag_names", None)
    tag_source = data.pop("tag_source", None)
    for field, value in data.items():
        setattr(game, field, value)
    if tag_names is not None:
        await _replace_game_tags(session, game, tag_names, tag_source)
    game.updated_at = datetime.utcnow()
    await session.commit()
    return {"message": "更新成功"}


async def _replace_game_tags(
    session: AsyncSession,
    game: Game,
    tag_names: list[str],
    source: str | None,
) -> None:
    source_name = str(source or "metadata").strip()[:32] or "metadata"
    normalized: list[str] = []
    seen: set[str] = set()
    for raw_name in tag_names:
        name = str(raw_name or "").strip()
        key = name.casefold()
        if not name or key in seen:
            continue
        seen.add(key)
        normalized.append(name)

    existing_result = await session.execute(
        select(GameTag).where(
            GameTag.game_id == game.id,
            GameTag.source != "user",
        )
    )
    for assoc in existing_result.scalars():
        await session.delete(assoc)
    await session.flush()

    for name in normalized:
        tag_result = await session.execute(select(Tag).where(Tag.name == name))
        tag = tag_result.scalar_one_or_none()
        if tag is None:
            tag = Tag(name=name)
            session.add(tag)
            await session.flush()
        assoc_result = await session.execute(
            select(GameTag).where(
                GameTag.game_id == game.id,
                GameTag.tag_id == tag.id,
            )
        )
        if assoc_result.scalar_one_or_none() is None:
            session.add(GameTag(game_id=game.id, tag_id=tag.id, source=source_name))


@router.put("/{game_id}/versions/{version_id}")
async def update_version(
    game_id: int,
    version_id: int,
    body: VersionUpdate,
    user: User = Depends(require_admin),
    session: AsyncSession = Depends(get_session),
):
    """Edit a game version's platform and extraction password (admin only)."""
    result = await session.execute(
        select(GameVersion).where(GameVersion.id == version_id, GameVersion.game_id == game_id)
    )
    version = result.scalar_one_or_none()
    if version is None:
        raise HTTPException(status_code=404, detail="Version not found")

    if body.platform is not None:
        platform_value = body.platform.strip()
        if platform_value == "KR":
            platform_value = "KRKR"
        try:
            version.platform = Platform(platform_value)
        except ValueError:
            allowed = ", ".join(p.value for p in Platform)
            raise HTTPException(status_code=400, detail=f"Invalid platform. Allowed: {allowed}")

    if body.extract_password is not None:
        password = body.extract_password.strip()
        version.extract_password = password or None

    await session.commit()
    return {
        "message": "Version updated",
        "version": {
            "id": version.id,
            "platform": version.platform.value,
            "filename": version.filename,
            "file_path": version.file_path,
            "file_size": version.file_size,
            "extract_password": version.extract_password,
        },
    }


@router.post("/{game_id}/versions/{version_id}/move")
async def move_version(
    game_id: int,
    version_id: int,
    to_game_id: int,
    user: User = Depends(require_admin),
    session: AsyncSession = Depends(get_session),
):
    """Move a game version to another game (admin only)."""
    result = await session.execute(
        select(GameVersion).where(GameVersion.id == version_id, GameVersion.game_id == game_id)
    )
    version = result.scalar_one_or_none()
    if version is None:
        raise HTTPException(status_code=404, detail="版本未找到")

    # Verify target game exists
    target = await session.execute(select(Game).where(Game.id == to_game_id))
    if target.scalar_one_or_none() is None:
        raise HTTPException(status_code=404, detail="目标游戏未找到")

    version.game_id = to_game_id
    await session.flush()

    # Clean up source game if it has no versions left
    from_game = await session.execute(select(Game).where(Game.id == game_id))
    from_g = from_game.scalar_one_or_none()
    if from_g:
        remaining = await session.execute(
            select(func.count(GameVersion.id)).where(GameVersion.game_id == game_id)
        )
        if remaining.scalar() == 0 and _entry_source(from_g) == "library":
            from_g.is_deleted = True
            from_g.updated_at = datetime.utcnow()
            await _add_ignore_path_once(session, from_g)

    await cleanup_empty_companies(session)
    await session.commit()
    return {"message": "版本已移动"}


@router.post("/{from_id}/merge/{to_id}")
async def merge_games(
    from_id: int,
    to_id: int,
    user: User = Depends(require_admin),
    session: AsyncSession = Depends(get_session),
):
    """Merge game A into game B: move all versions and delete game A (admin only)."""
    from_g = (await session.execute(select(Game).where(Game.id == from_id))).scalar_one_or_none()
    to_g = (await session.execute(select(Game).where(Game.id == to_id))).scalar_one_or_none()
    if from_g is None or to_g is None:
        raise HTTPException(status_code=404, detail="游戏未找到")

    # Move all versions
    versions = await session.execute(
        select(GameVersion).where(GameVersion.game_id == from_id)
    )
    for v in versions.scalars().all():
        v.game_id = to_id

    # Soft delete source game
    from_g.is_deleted = True
    from_g.updated_at = datetime.utcnow()
    await _add_ignore_path_once(session, from_g)

    await cleanup_empty_companies(session)
    await session.commit()
    return {"message": "合并完成"}
