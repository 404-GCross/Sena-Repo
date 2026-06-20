"""Steam patch injection API — PC client feature.

Reads patches.json in the patch directory for patch index.
Falls back to bare file scanning if no patches.json exists.
"""
from __future__ import annotations

import json, re
from pathlib import Path

from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.orm import joinedload
from sqlalchemy.ext.asyncio import AsyncSession

from config import load_config
from database import get_session

router = APIRouter(prefix="/api/steam", tags=["steam-patch"])


def _get_patches_dir(config=None):
    if config is None:
        config = load_config()
    return Path(config.patch_dir) if config.patch_dir else Path(config.data_path) / "steam_patches"


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


# ── Patch-type keyword matching ──

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
    """Load patch_type_keywords.json; create with defaults if missing."""
    kw_path = _get_type_keywords_path(patches_dir)
    if kw_path.is_file():
        try:
            with open(kw_path, "r", encoding="utf-8") as f:
                data = json.load(f)
            if isinstance(data, dict):
                return {k: v for k, v in data.items() if isinstance(v, list)}
        except Exception:
            pass
    # Create default
    patches_dir.mkdir(parents=True, exist_ok=True)
    with open(kw_path, "w", encoding="utf-8") as f:
        json.dump(DEFAULT_TYPE_KEYWORDS, f, ensure_ascii=False, indent=2)
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
    with open(_get_type_keywords_path(patches_dir), "w", encoding="utf-8") as f:
        json.dump(keywords, f, ensure_ascii=False, indent=2)


# ── Models ──

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


# ── Endpoints ──

@router.post("/scan", response_model=list[PatchMatch])
async def scan_steam_games(body: ScanRequest):
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
            patch_file = patches_dir / entry["file"]
            if patch_file.is_file():
                match.patch_available = True
                match.patch_filename = patch_file.name
                match.patch_size = patch_file.stat().st_size
                match.patch_dir = entry.get("patch_dir", "")
                match.target_dir = entry.get("target_dir", "")
                match.label = entry.get("label", "")
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
async def list_patches(session: AsyncSession = Depends(get_session)):
    """List all patches. Auto-scans if no patches.json. Matches by game name if no app_id."""
    patches_dir = _get_patches_dir()
    patches_dir.mkdir(parents=True, exist_ok=True)

    # Auto-scan if no patches.json
    json_path = patches_dir / "patches.json"
    if not json_path.is_file():
        try:
            from scan_patches import scan_patches_dir, load_existing, merge
            scanned = scan_patches_dir(patches_dir)
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
async def download_patch(app_id: str, request: Request):
    patches_dir = _get_patches_dir()
    if not patches_dir.exists():
        raise HTTPException(status_code=404, detail="补丁目录不存在")

    # 1. Try patches.json
    index = _load_patches_index(patches_dir)
    if index and app_id in index:
        entry = index[app_id]
        patch_file = patches_dir / entry["file"]
        if patch_file.is_file():
            return FileResponse(path=str(patch_file), filename=patch_file.name,
                                media_type="application/octet-stream",
                                headers={"Accept-Ranges": "bytes"})

    # 2. Fallback
    patch_file = _find_patch_fallback(patches_dir, app_id)
    if patch_file is None:
        raise HTTPException(status_code=404, detail=f"未找到 App ID {app_id} 的补丁文件")
    return FileResponse(path=str(patch_file), filename=patch_file.name,
                        media_type="application/octet-stream",
                        headers={"Accept-Ranges": "bytes"})


class PatchUpdate(BaseModel):
    patch_dir: str | None = None
    target_dir: str | None = None
    label: str | None = None
    type: str | None = None
    app_id: str | None = None  # new app_id to update
    file: str | None = None    # lookup by file path if app_id is None/unknown


@router.put("/patches/{lookup_key}")
async def update_patch(lookup_key: str, body: PatchUpdate):
    """Update patch metadata in patches.json. lookup_key can be app_id or file path."""
    import json as _json
    patches_dir = _get_patches_dir()
    json_path = patches_dir / "patches.json"

    if not json_path.is_file():
        raise HTTPException(status_code=404, detail="patches.json 不存在")

    try:
        with open(json_path, "r", encoding="utf-8") as f:
            data = _json.load(f)
    except Exception:
        raise HTTPException(status_code=400, detail="patches.json 格式错误")

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
            return {"message": "已更新", "lookup_key": lookup_key}

    raise HTTPException(status_code=404, detail=f"未找到 App ID/File: {lookup_key}")


# ── Patch scan endpoint ──

@router.post("/scan-patches")
async def scan_patches_endpoint():
    """Re-scan the patch directory and regenerate patches.json."""
    patches_dir = _get_patches_dir()
    patches_dir.mkdir(parents=True, exist_ok=True)
    try:
        from scan_patches import scan_patches_dir, load_existing, merge
        scanned = scan_patches_dir(patches_dir)
        json_path = patches_dir / "patches.json"
        existing = load_existing(json_path)
        existing_list = existing.get("patches", []) if existing else []
        merged_patches = merge(existing_list, scanned)
        with open(json_path, "w", encoding="utf-8") as f:
            json.dump({"patches": merged_patches}, f, ensure_ascii=False, indent=2)
        return {"message": "扫描完成", "scanned": len(scanned), "directory": str(patches_dir)}
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"补丁扫描失败: {e}")


# ── Patch type keywords API ──

@router.get("/patch-type-keywords")
async def get_type_keywords():
    """Return patch_type_keywords.json content."""
    patches_dir = _get_patches_dir()
    return _load_type_keywords(patches_dir)


class TypeKeywordsUpdate(BaseModel):
    keywords: dict[str, list[str]]


@router.put("/patch-type-keywords")
async def update_type_keywords(body: TypeKeywordsUpdate):
    """Overwrite patch_type_keywords.json."""
    patches_dir = _get_patches_dir()
    _save_type_keywords(patches_dir, body.keywords)
    return {"message": "关键词已更新"}


def _find_patch_fallback(patches_dir: Path, app_id: str) -> Path | None:
    for ext in (".zip", ".rar", ".7z", ".tar", ".gz"):
        candidate = patches_dir / f"{app_id}{ext}"
        if candidate.exists():
            return candidate
    app_dir = patches_dir / app_id
    if app_dir.is_dir():
        for ext in (".zip", ".rar", ".7z"):
            for f in app_dir.iterdir():
                if f.is_file() and f.suffix.lower() == ext:
                    return f
    return None
