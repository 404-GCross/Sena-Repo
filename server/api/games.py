"""Game browsing and management API."""

from __future__ import annotations

from datetime import datetime
from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import select, or_
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import joinedload, selectinload

from api.auth import get_current_user
from database import get_session
from models.user import User
from models.game import Company, Game, GameVersion, GameTag
from models.ignore_list import IgnoreList
from models.tag import Tag
from schemas.common import MessageResponse
from schemas.game import GameDetail, GameSummary

router = APIRouter(prefix="/api/games", tags=["games"])


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
        cover_path=game.cover_path,
        platform_summary=", ".join(platforms),
        tag_names=tag_names,
        imported_at=game.imported_at,
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
):
    """List games with optional filters and sorting.

    Filters: tag, platform, root_id, developer, has_cover
    Sort options: imported (default), name, name_desc, company, developer
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
        cover_path=game.cover_path,
        bg_path=game.bg_path,
        developer=game.developer,
        description=game.description,
        release_date=game.release_date,
        vndb_id=game.vndb_id,
        steam_id=game.steam_id,
        bangumi_id=game.bangumi_id,
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
            }
            for v in game.versions
        ],
        tags=[
            {"id": gt.tag.id, "name": gt.tag.name, "color": gt.tag.color, "created_at": gt.tag.created_at}
            for gt in game.tags
        ],
    )


@router.delete("/{game_id}", response_model=MessageResponse)
async def delete_game(
    game_id: int,
    user: User = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
):
    """Soft-delete a game: mark as deleted and add folder to ignore list."""
    result = await session.execute(
        select(Game).where(Game.id == game_id)
    )
    game = result.scalar_one_or_none()
    if game is None:
        raise HTTPException(status_code=404, detail="Game not found")

    # Soft delete
    game.is_deleted = True
    game.updated_at = datetime.utcnow()

    # Add to ignore list
    existing = await session.execute(
        select(IgnoreList).where(IgnoreList.path == game.folder_path)
    )
    if existing.scalar_one_or_none() is None:
        session.add(IgnoreList(path=game.folder_path))

    await session.commit()
    return MessageResponse(message=f"Game '{game.name}' removed")


from pydantic import BaseModel

class BatchDeleteRequest(BaseModel):
    game_ids: list[int]

@router.post("/batch-delete", response_model=MessageResponse)
async def batch_delete_games(
    body: BatchDeleteRequest,
    user: User = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
):
    """Soft-delete multiple games at once."""
    if not body.game_ids:
        return MessageResponse(message="没有要删除的游戏")
    # Single query for all games
    result = await session.execute(
        select(Game).where(Game.id.in_(body.game_ids)))
    games = result.scalars().all()
    paths = {g.folder_path for g in games if g.folder_path}
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
        if game.folder_path and game.folder_path not in ignored_paths:
            session.add(IgnoreList(path=game.folder_path))
            ignored_paths.add(game.folder_path)
        deleted += 1
    await session.commit()
    return MessageResponse(message=f"已删除 {deleted} 个游戏")


class QuickCreate(BaseModel):
    name: str


@router.put("/quick-create")
async def quick_create_game(
    body: QuickCreate,
    user: User = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
):
    """Quick-create a minimal game entry (for version moving)."""
    game = Game(name=body.name, root_id=0, folder_path=f"/virtual/{body.name}")
    session.add(game)
    await session.commit()
    await session.refresh(game)
    return {"id": game.id, "name": game.name}


class GameUpdate(BaseModel):
    name: str | None = None
    developer: str | None = None
    description: str | None = None
    release_date: str | None = None
    bg_path: str | None = None
    vndb_id: str | None = None
    steam_id: str | None = None
    bangumi_id: str | None = None


@router.put("/{game_id}")
async def update_game(
    game_id: int,
    body: GameUpdate,
    user: User = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
):
    """Edit game metadata."""
    result = await session.execute(select(Game).where(Game.id == game_id))
    game = result.scalar_one_or_none()
    if game is None:
        raise HTTPException(status_code=404, detail="Game not found")

    for field, value in body.model_dump(exclude_unset=True).items():
        if value is not None:
            setattr(game, field, value)
    game.updated_at = datetime.utcnow()
    await session.commit()
    return {"message": "更新成功"}


@router.post("/{game_id}/versions/{version_id}/move")
async def move_version(
    game_id: int,
    version_id: int,
    to_game_id: int,
    session: AsyncSession = Depends(get_session),
):
    """Move a game version to another game."""
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
    await session.commit()
    return {"message": "版本已移动"}


@router.post("/{from_id}/merge/{to_id}")
async def merge_games(
    from_id: int,
    to_id: int,
    user: User = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
):
    """Merge game A into game B: move all versions and delete game A."""
    from_game = await session.execute(select(Game).where(Game.id == from_id))
    to_game = await session.execute(select(Game).where(Game.id == to_id))
    if from_game.scalar_one_or_none() is None or to_game.scalar_one_or_none() is None:
        raise HTTPException(status_code=404, detail="游戏未找到")

    # Move all versions
    versions = await session.execute(
        select(GameVersion).where(GameVersion.game_id == from_id)
    )
    for v in versions.scalars().all():
        v.game_id = to_id

    # Soft delete source game
    from_g = from_game.scalar_one()
    from_g.is_deleted = True
    from_g.updated_at = datetime.utcnow()
    session.add(IgnoreList(path=from_g.folder_path))

    await session.commit()
    return {"message": "合并完成"}
