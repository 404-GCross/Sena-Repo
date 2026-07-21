"""Steam patch injection API 鈥?PC client feature.

Reads patches.json in the patch directory for patch index.
Falls back to bare file scanning if no patches.json exists.
"""
from __future__ import annotations

import asyncio, json, logging, re
from pathlib import Path

from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.orm import joinedload
from sqlalchemy.ext.asyncio import AsyncSession

from config import load_config
from database import get_session
from models.user import User
from models.file_source import FileSource, SteamPatchRoot
from api.auth import get_current_user, require_admin
from services.file_source import adapter_from_source, canonical_source_path, normalize_remote_path

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/steam", tags=["steam-patch"])


def _get_patches_dir(config=None):
    if config is None:
        config = load_config()
    return Path(config.patch_dir) if config.patch_dir else Path(config.data_path) / "steam_patches"


async def _patch_roots(session: AsyncSession) -> list[SteamPatchRoot]:
    result = await session.execute(select(SteamPatchRoot).order_by(SteamPatchRoot.id))
    roots = result.scalars().all()
    if roots:
        return roots
    config = load_config()
    default_dir = str(_get_patches_dir(config))
    return [SteamPatchRoot(id=0, source_type="local", path=default_dir)]


class PatchRootCreate(BaseModel):
    path: str = Field(min_length=1, max_length=1024)
    source_type: str = "local"
    source_id: int | None = None
    source_name: str | None = None
    base_url: str | None = None
    username: str | None = None
    password: str | None = None


class PatchRootOut(BaseModel):
    id: int
    path: str
    source_type: str = "local"
    source_id: int | None = None
    source_name: str | None = None

    model_config = {"from_attributes": True}


@router.get("/patch-roots", response_model=list[PatchRootOut])
async def list_patch_roots(user: User = Depends(require_admin), session: AsyncSession = Depends(get_session)):
    return await _patch_roots(session)


@router.post("/patch-roots", response_model=PatchRootOut, status_code=201)
async def add_patch_root(
    body: PatchRootCreate,
    user: User = Depends(require_admin),
    session: AsyncSession = Depends(get_session),
):
    source_type = body.source_type if body.source_type in {"local", "openlist"} else "local"
    source_id = body.source_id
    source_name = body.source_name
    path = body.path if source_type == "local" else normalize_remote_path(body.path)
    if source_type == "openlist":
        source = None
        if source_id:
            result = await session.execute(select(FileSource).where(FileSource.id == source_id))
            source = result.scalar_one_or_none()
            if source is None:
                raise HTTPException(status_code=404, detail="OpenList source not found")
        else:
            if not body.base_url or not body.username:
                raise HTTPException(status_code=400, detail="OpenList URL and username are required")
            source = FileSource(
                name=source_name or body.base_url,
                type="openlist",
                base_url=body.base_url.rstrip("/"),
                username=body.username,
                password=body.password or "",
            )
            session.add(source)
            await session.flush()
            source_id = source.id
        adapter = adapter_from_source(source, "openlist")
        if not await asyncio.to_thread(adapter.exists, path):
            raise HTTPException(status_code=404, detail="OpenList path not found")
        source_name = source.name
    root = SteamPatchRoot(source_type=source_type, source_id=source_id, source_name=source_name, path=path)
    session.add(root)
    await session.commit()
    await session.refresh(root)
    return root


@router.put("/patch-roots/{root_id}", response_model=PatchRootOut)
async def update_patch_root(
    root_id: int,
    body: PatchRootCreate,
    user: User = Depends(require_admin),
    session: AsyncSession = Depends(get_session),
):
    result = await session.execute(select(SteamPatchRoot).where(SteamPatchRoot.id == root_id))
    root = result.scalar_one_or_none()
    if root is None:
        raise HTTPException(status_code=404, detail="Patch root not found")

    source_type = body.source_type if body.source_type in {"local", "openlist"} else "local"
    source_id = body.source_id
    source_name = body.source_name
    path = body.path if source_type == "local" else normalize_remote_path(body.path)
    if source_type == "openlist":
        source = None
        if source_id:
            result = await session.execute(select(FileSource).where(FileSource.id == source_id))
            source = result.scalar_one_or_none()
            if source is None:
                raise HTTPException(status_code=404, detail="OpenList source not found")
        else:
            if not body.base_url or not body.username:
                raise HTTPException(status_code=400, detail="OpenList source must be selected first")
            source = FileSource(
                name=source_name or body.base_url,
                type="openlist",
                base_url=body.base_url.rstrip("/"),
                username=body.username,
                password=body.password or "",
            )
            session.add(source)
            await session.flush()
            source_id = source.id
        adapter = adapter_from_source(source, "openlist")
        if not await asyncio.to_thread(adapter.exists, path):
            raise HTTPException(status_code=404, detail="OpenList path not found")
        source_name = source.name

    root.source_type = source_type
    root.source_id = source_id
    root.source_name = source_name
    root.path = path
    await session.commit()
    await session.refresh(root)
    return root


@router.delete("/patch-roots/{root_id}")
async def delete_patch_root(root_id: int, user: User = Depends(require_admin), session: AsyncSession = Depends(get_session)):
    result = await session.execute(select(SteamPatchRoot).where(SteamPatchRoot.id == root_id))
    root = result.scalar_one_or_none()
    if root is None:
        raise HTTPException(status_code=404, detail="Patch root not found")
    await session.delete(root)
    await session.commit()
    return {"message": "Patch root removed"}


def _load_patches_index(patches_dir: Path) -> dict[str, dict] | None:
    """Load patches.json; returns dict keyed by app_id string (only for patches with valid app_id)."""
    idx_path = patches_dir / "patches.json"
    if not idx_path.is_file():
        return None
    try:
        with open(idx_path, "r", encoding="utf-8") as f:
            data = json.load(f)
        patches = data.get("patches", [])
        idx = {}
        for p in patches:
            aid = p.get("app_id")
            if aid is not None and str(aid) != "None" and aid != 0:
                idx[str(aid)] = p
        return idx
    except Exception:
        return None


def _load_all_patches(patches_dir: Path) -> list[dict]:
    """Load ALL patches from patches.json, including those with null app_id."""
    idx_path = patches_dir / "patches.json"
    if not idx_path.is_file():
        return []
    try:
        with open(idx_path, "r", encoding="utf-8") as f:
            data = json.load(f)
        return data.get("patches", [])
    except Exception:
        return []


# 鈹€鈹€ Patch-type keyword matching 鈹€鈹€

_KEYWORD_VERSION = 1  # bump when DEFAULT_TYPE_KEYWORDS changes to force migration

DEFAULT_TYPE_KEYWORDS = {
    "translation": ["_Steam_Chinese_Patch"],
    "voice": ["_Steam_Voice_Patch"],
    "story": ["_Steam_Story_Patch"],
    "extra": ["_Steam_Extra_Patch"],
    "misc": [],
}


def _get_type_keywords_path(patches_dir: Path) -> Path:
    return patches_dir / "patch_type_keywords.json"


def _load_type_keywords(patches_dir: Path) -> dict[str, list[str]]:
    """Load patch_type_keywords.json; create/overwrite with defaults if missing or outdated."""
    kw_path = _get_type_keywords_path(patches_dir)
    if kw_path.is_file():
        try:
            with open(kw_path, "r", encoding="utf-8") as f:
                data = json.load(f)
            if isinstance(data, dict) and data.get("_version") == _KEYWORD_VERSION:
                return {k: v for k, v in data.items() if k != "_version" and isinstance(v, list)}
        except Exception:
            pass
    # Create / overwrite with current defaults
    patches_dir.mkdir(parents=True, exist_ok=True)
    defaults = {"_version": _KEYWORD_VERSION, **DEFAULT_TYPE_KEYWORDS}
    with open(kw_path, "w", encoding="utf-8") as f:
        json.dump(defaults, f, ensure_ascii=False, indent=2)
    return dict(DEFAULT_TYPE_KEYWORDS)


def _guess_type_by_keywords(filename: str, keywords: dict[str, list[str]]) -> str | None:
    """Match filename (case-insensitive) against keyword dict; return first matching type."""
    lower = filename.lower()
    for ptype, words in keywords.items():
        if ptype == "misc":
            continue
        for w in words:
            if w.lower() in lower:
                return ptype
    return None


def _save_type_keywords(patches_dir: Path, keywords: dict[str, list[str]]):
    patches_dir.mkdir(parents=True, exist_ok=True)
    data = {"_version": _KEYWORD_VERSION, **keywords}
    with open(_get_type_keywords_path(patches_dir), "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)


# 鈹€鈹€ Models 鈹€鈹€

class SteamGameInfo(BaseModel):
    app_id: str
    name: str
    install_dir: str


class PatchMatch(BaseModel):
    app_id: str
    game_name: str
    install_dir: str
    patch_available: bool
    patch_filename: str | None = None
    patch_size: int = 0
    patch_dir: str | None = None
    target_dir: str | None = None
    label: str | None = None
    type: str | None = None  # translation/voice/story/extra/misc


class ScanRequest(BaseModel):
    games: list[SteamGameInfo]


# 鈹€鈹€ Endpoints 鈹€鈹€

@router.post("/scan", response_model=list[PatchMatch])
async def scan_steam_games(body: ScanRequest, user: User = Depends(get_current_user)):
    config = load_config()
    patches_dir = _get_patches_dir(config)
    index = _load_patches_index(patches_dir)
    keywords = _load_type_keywords(patches_dir)
    results = []

    for game in body.games:
        match = PatchMatch(
            app_id=game.app_id,
            game_name=game.name,
            install_dir=game.install_dir,
            patch_available=False,
        )

        if not patches_dir.exists():
            results.append(match)
            continue

        # 1. Try patches.json index
        if index and game.app_id in index:
            entry = index[game.app_id]
            if entry.get("source_type") == "openlist":
                match.patch_available = True
                match.patch_filename = (entry.get("display_file") or entry.get("source_path") or entry.get("file", "")).split("/")[-1]
                match.patch_size = int(entry.get("size") or 0)
                match.patch_dir = entry.get("patch_dir", "")
                match.target_dir = entry.get("target_dir", "")
                match.label = entry.get("label", "")
                if entry.get("game_name"):
                    match.game_name = entry["game_name"]
                match.type = entry.get("type", "misc") or "misc"
                results.append(match)
                continue
            patch_file = _safe_patch_path(patches_dir, entry.get("file", ""))
            if patch_file and patch_file.is_file():
                match.patch_available = True
                match.patch_filename = patch_file.name
                match.patch_size = patch_file.stat().st_size
                match.patch_dir = entry.get("patch_dir", "")
                match.target_dir = entry.get("target_dir", "")
                match.label = entry.get("label", "")
                # Use game_name from patches.json if available (Chinese name from Steam)
                if entry.get("game_name"):
                    match.game_name = entry["game_name"]
                # Type: keep existing if already set (non-misc), else keyword-guess
                existing_type = entry.get("type", "misc")
                if existing_type and existing_type != "misc":
                    match.type = existing_type
                else:
                    guessed = _guess_type_by_keywords(match.patch_filename or "", keywords)
                    match.type = guessed or existing_type or "misc"
                results.append(match)
                continue

        # 2. Fallback: bare file scan
        patch_file = _find_patch_fallback(patches_dir, game.app_id)
        if patch_file:
            match.patch_available = True
            match.patch_filename = patch_file.name
            match.patch_size = patch_file.stat().st_size
            # Keyword guess for bare files
            guessed = _guess_type_by_keywords(patch_file.name, keywords)
            if guessed:
                match.type = guessed

        results.append(match)

    return results


@router.get("/patches")
async def list_patches(session: AsyncSession = Depends(get_session), user: User = Depends(get_current_user)):
    """List all patches. Auto-scans if no patches.json. Matches by game name if no app_id."""
    patches_dir = _get_patches_dir()
    patches_dir.mkdir(parents=True, exist_ok=True)

    # Auto-scan if no patches.json
    json_path = patches_dir / "patches.json"
    if not json_path.is_file():
        try:
            from scan_patches import scan_patches_dir, scan_patches_source, load_existing, merge
            scanned = []
            roots = await _patch_roots(session)
            for root in roots:
                if root.source_type == "openlist":
                    result = await session.execute(select(FileSource).where(FileSource.id == root.source_id))
                    source = result.scalar_one_or_none()
                    adapter = adapter_from_source(source, "openlist")
                    scanned.extend(await asyncio.to_thread(scan_patches_source, adapter, root.path, "openlist", root.source_id))
                else:
                    scanned.extend(await asyncio.to_thread(scan_patches_dir, Path(root.path)))
            if scanned:
                existing = load_existing(json_path)
                existing_list = existing.get("patches", []) if existing else []
                merged_patches = merge(existing_list, scanned)
                with open(json_path, "w", encoding="utf-8") as f:
                    json.dump({"patches": merged_patches}, f, ensure_ascii=False, indent=2)
        except Exception:
            pass

    patches = _load_all_patches(patches_dir)

    # Match patches without app_id to games in DB by name
    if patches:
        try:
            from models.game import Game as _Game
            result = await session.execute(
                select(_Game).where(_Game.is_deleted == False).options(joinedload(_Game.company))
            )
            games = result.unique().scalars().all()

            for p in patches:
                aid = p.get("app_id")
                if aid is not None and str(aid) != "None" and aid != 0:
                    continue
                filename = p.get("file", "").split("/")[-1]
                for game in games:
                    if game.name and game.name.lower() in filename.lower():
                        p["app_id"] = game.id
                        p["matched_game"] = game.name
                        p["matched_company"] = game.company.name if game.company else None
                        break
        except Exception:
            pass

    return {"patches": patches, "count": len(patches), "source": "patches.json"}


@router.get("/patches/{app_id}/download")
async def download_patch(
    app_id: str,
    request: Request,
    user: User = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
):
    patches_dir = _get_patches_dir()

    index = _load_patches_index(patches_dir)
    if index and app_id in index:
        entry = index[app_id]
        if entry.get("source_type") == "openlist":
            result = await session.execute(select(FileSource).where(FileSource.id == entry.get("source_id")))
            source = result.scalar_one_or_none()
            adapter = adapter_from_source(source, "openlist")
            raw_url = await asyncio.to_thread(adapter.download_url, entry.get("source_path") or entry.get("file", ""))
            from fastapi.responses import RedirectResponse
            return RedirectResponse(raw_url, status_code=302)
        patch_file = _safe_patch_path(patches_dir, entry.get("file", ""))
        if patch_file and patch_file.is_file():
            return FileResponse(
                path=str(patch_file),
                filename=patch_file.name,
                media_type="application/octet-stream",
                headers={"Accept-Ranges": "bytes"},
            )

    if not patches_dir.exists():
        raise HTTPException(status_code=404, detail="Patch directory not found")
    patch_file = _find_patch_fallback(patches_dir, app_id)
    if patch_file is None:
        raise HTTPException(status_code=404, detail=f"Patch file for App ID {app_id} not found")
    return FileResponse(
        path=str(patch_file),
        filename=patch_file.name,
        media_type="application/octet-stream",
        headers={"Accept-Ranges": "bytes"},
    )

class PatchUpdate(BaseModel):
    patch_dir: str | None = None
    target_dir: str | None = None
    label: str | None = None
    type: str | None = None
    app_id: str | None = None  # new app_id to update
    file: str | None = None    # lookup by file path if app_id is None/unknown


@router.put("/patches/{lookup_key}")
async def update_patch(lookup_key: str, body: PatchUpdate, user: User = Depends(require_admin)):
    """Update patch metadata in patches.json. lookup_key can be app_id or file path."""
    import json as _json
    patches_dir = _get_patches_dir()
    json_path = patches_dir / "patches.json"

    if not json_path.is_file():
        raise HTTPException(status_code=404, detail="patches.json not found")

    try:
        with open(json_path, "r", encoding="utf-8") as f:
            data = _json.load(f)
    except Exception:
        raise HTTPException(status_code=400, detail="patches.json 鏍煎紡閿欒")

    patches = data.get("patches", [])
    for p in patches:
        # Match by app_id OR by file path
        matched = str(p.get("app_id", "")) == lookup_key
        if not matched and p.get("file", "") == lookup_key:
            matched = True
        if not matched and body.file and p.get("file", "") == body.file:
            matched = True
        if matched:
            if body.patch_dir is not None:
                p["patch_dir"] = body.patch_dir
            if body.target_dir is not None:
                p["target_dir"] = body.target_dir
            if body.label is not None:
                p["label"] = body.label
            if body.type is not None:
                p["type"] = body.type
            if body.app_id is not None and body.app_id != "":
                p["app_id"] = int(body.app_id) if body.app_id.isdigit() else body.app_id
            with open(json_path, "w", encoding="utf-8") as f:
                _json.dump(data, f, ensure_ascii=False, indent=2)
            return {"message": "Updated", "lookup_key": lookup_key}

    raise HTTPException(status_code=404, detail=f"鏈壘鍒?App ID/File: {lookup_key}")


# 鈹€鈹€ Patch scan endpoint 鈹€鈹€

@router.post("/scan-patches")
async def scan_patches_endpoint(user: User = Depends(require_admin), session: AsyncSession = Depends(get_session)):
    """Re-scan all configured patch roots and regenerate patches.json."""
    index_dir = _get_patches_dir()
    index_dir.mkdir(parents=True, exist_ok=True)
    try:
        from scan_patches import scan_patches_dir, scan_patches_source, load_existing, merge

        scanned = []
        roots = await _patch_roots(session)
        for root in roots:
            if root.source_type == "openlist":
                result = await session.execute(select(FileSource).where(FileSource.id == root.source_id))
                source = result.scalar_one_or_none()
                adapter = adapter_from_source(source, "openlist")
                scanned.extend(await asyncio.to_thread(scan_patches_source, adapter, root.path, "openlist", root.source_id))
                continue

            root_path = Path(root.path)
            local_scanned = await asyncio.to_thread(scan_patches_dir, root_path)
            for item in local_scanned:
                item["source_type"] = "local"
                item["source_id"] = None
                item["source_path"] = str(root_path / item["file"])
                if root_path.resolve() != index_dir.resolve():
                    item["file"] = str(root_path / item["file"])
            scanned.extend(local_scanned)

        json_path = index_dir / "patches.json"
        existing = load_existing(json_path)
        existing_list = existing.get("patches", []) if existing else []
        merged_patches = merge(existing_list, scanned)
        with open(json_path, "w", encoding="utf-8") as f:
            json.dump({"patches": merged_patches}, f, ensure_ascii=False, indent=2)
        return {"message": "扫描完成", "scanned": len(scanned), "directory": str(index_dir)}
    except Exception as e:
        logger.error(f"Patch scan failed: {e}")
        raise HTTPException(status_code=500, detail="Patch scan failed; check server logs")

# 鈹€鈹€ Patch type keywords API 鈹€鈹€

@router.get("/patch-type-keywords")
async def get_type_keywords(user: User = Depends(get_current_user)):
    """Return patch_type_keywords.json content."""
    patches_dir = _get_patches_dir()
    return _load_type_keywords(patches_dir)


class TypeKeywordsUpdate(BaseModel):
    keywords: dict[str, list[str]]


@router.put("/patch-type-keywords")
async def update_type_keywords(body: TypeKeywordsUpdate, user: User = Depends(require_admin)):
    """Overwrite patch_type_keywords.json (admin only)."""
    patches_dir = _get_patches_dir()
    _save_type_keywords(patches_dir, body.keywords)
    return {"message": "鍏抽敭璇嶅凡鏇存柊"}


def _safe_patch_path(patches_dir: Path, filename: str) -> Path | None:
    """Resolve a patch file path and verify it stays within patches_dir."""
    if not filename:
        return None
    resolved = (patches_dir / filename).resolve()
    try:
        resolved.relative_to(patches_dir.resolve())
    except ValueError:
        return None  # path traversal attempt
    return resolved


def _find_patch_fallback(patches_dir: Path, app_id: str) -> Path | None:
    # Only use basename of app_id to prevent path traversal
    safe_name = Path(app_id.replace("\\", "/")).name
    if not safe_name or safe_name in (".", ".."):
        return None
    for ext in (".zip", ".rar", ".7z", ".tar", ".gz"):
        candidate = patches_dir / f"{safe_name}{ext}"
        if candidate.is_file():
            return candidate
    app_dir = patches_dir / safe_name
    if app_dir.is_dir():
        for ext in (".zip", ".rar", ".7z"):
            for f in app_dir.iterdir():
                if f.is_file() and f.suffix.lower() == ext:
                    return f
    return None


# 鈹€鈹€ Patch ID re-scrape 鈹€鈹€

class RescrapeResult(BaseModel):
    lookup_key: str
    file: str = ""
    old_app_id: str = ""
    new_app_id: str = ""
    game_name: str = ""
    status: str = ""  # "updated" / "skipped" / "not_found" / "error"


@router.post("/patches/{lookup_key}/rescrape")
async def rescrape_patch(lookup_key: str, user: User = Depends(require_admin)):
    """Re-search Steam for a single patch's app_id and update patches.json."""
    import asyncio as _asyncio
    patches_dir = _get_patches_dir()
    json_path = patches_dir / "patches.json"

    if not json_path.is_file():
        raise HTTPException(status_code=404, detail="patches.json not found")

    try:
        with open(json_path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        raise HTTPException(status_code=400, detail="patches.json 鏍煎紡閿欒")

    patches = data.get("patches", [])
    target = None
    for p in patches:
        if str(p.get("app_id", "")) == lookup_key:
            target = p; break
        if p.get("file", "") == lookup_key:
            target = p; break

    if target is None:
        raise HTTPException(status_code=404, detail=f"鏈壘鍒拌ˉ涓? {lookup_key}")

    old_app_id = str(target.get("app_id", "") or "")
    filename = target.get("file", "").split("/")[-1]
    from scan_patches import _extract_game_name, _search_steam_app_id, _fetch_game_name
    game_name_candidate = _extract_game_name(filename)

    try:
        new_id = await _asyncio.to_thread(_search_steam_app_id, game_name_candidate)
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Steam API 鏌ヨ澶辫触: {e}")

    result = RescrapeResult(
        lookup_key=lookup_key,
        file=filename,
        old_app_id=old_app_id,
        status="not_found",
    )

    if new_id:
        target["app_id"] = new_id
        result.new_app_id = str(new_id)
        result.status = "updated"
        # Also fetch game name
        try:
            name = await _asyncio.to_thread(_fetch_game_name, new_id)
            if name:
                target["game_name"] = name
                result.game_name = name
        except Exception:
            pass
    elif old_app_id:
        result.status = "skipped"
        result.new_app_id = old_app_id

    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)

    return result


@router.post("/patches/rescrape-all")
async def rescrape_all_patches(user: User = Depends(require_admin)):
    """Re-search Steam for all patches' app_ids (batch)."""
    import asyncio as _asyncio
    patches_dir = _get_patches_dir()
    json_path = patches_dir / "patches.json"

    if not json_path.is_file():
        raise HTTPException(status_code=404, detail="patches.json not found")

    try:
        with open(json_path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        raise HTTPException(status_code=400, detail="patches.json 鏍煎紡閿欒")

    patches = data.get("patches", [])
    from scan_patches import _extract_game_name, _search_steam_app_id, _fetch_game_name

    results: list[RescrapeResult] = []

    async def rescrape_one(p: dict) -> RescrapeResult:
        filename = p.get("file", "").split("/")[-1]
        old_id = str(p.get("app_id", "") or "")
        lookup = old_id or p.get("file", "")
        game_name_candidate = _extract_game_name(filename)

        r = RescrapeResult(lookup_key=lookup, file=filename, old_app_id=old_id)

        if not game_name_candidate:
            r.status = "skipped"
            return r

        try:
            new_id = await _asyncio.to_thread(_search_steam_app_id, game_name_candidate)
        except Exception:
            r.status = "error"
            return r

        if new_id:
            p["app_id"] = new_id
            r.new_app_id = str(new_id)
            r.status = "updated"
            try:
                name = await _asyncio.to_thread(_fetch_game_name, new_id)
                if name:
                    p["game_name"] = name
                    r.game_name = name
            except Exception:
                pass
        elif old_id:
            r.new_app_id = old_id
            r.status = "skipped"
        else:
            r.status = "not_found"

        return r

    tasks = [rescrape_one(p) for p in patches]
    results = await _asyncio.gather(*tasks)
    updated = sum(1 for r in results if r.status == "updated")

    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)

    return {"message": f"Batch rescrape completed: {updated} updated", "updated": updated, "total": len(patches), "results": [r.model_dump() for r in results]}


# 鈹€鈹€ Steam game name resolution 鈹€鈹€

class AppIdList(BaseModel):
    appids: list[str]


@router.post("/game-names")
async def get_game_names(body: AppIdList, user: User = Depends(get_current_user)):
    """Resolve Steam AppIDs to Chinese game names via Store API."""
    import httpx
    import asyncio

    results: dict[str, str] = {}
    sem = asyncio.Semaphore(5)

    async def resolve(appid: str):
        async with sem:
            try:
                async with httpx.AsyncClient(timeout=httpx.Timeout(10.0)) as client:
                    for lang in ("schinese", "english"):
                        resp = await client.get(
                            f"https://store.steampowered.com/api/appdetails?appids={appid}&l={lang}"
                        )
                        if resp.status_code == 200:
                            data = resp.json()
                            details = (data.get(str(appid)) or {}).get("data") or {}
                            name = details.get("name", "")
                            if name:
                                results[appid] = name
                                return
            except Exception:
                pass

    tasks = [resolve(a) for a in body.appids]
    await asyncio.gather(*tasks)
    return results
