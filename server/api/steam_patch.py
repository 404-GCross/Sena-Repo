"""Steam patch injection API — PC client feature.

Reads patches.json in the patch directory for patch index.
Falls back to bare file scanning if no patches.json exists.
"""
from __future__ import annotations

import json, re
from pathlib import Path

from fastapi import APIRouter, HTTPException
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field

from config import load_config

router = APIRouter(prefix="/api/steam", tags=["steam-patch"])


def _get_patches_dir(config=None):
    if config is None:
        config = load_config()
    return Path(config.patch_dir) if config.patch_dir else Path(config.data_path) / "steam_patches"


def _load_patches_index(patches_dir: Path) -> dict[str, dict] | None:
    """Load patches.json; returns dict keyed by app_id string, or None if no file."""
    idx_path = patches_dir / "patches.json"
    if not idx_path.is_file():
        return None
    try:
        with open(idx_path, "r", encoding="utf-8") as f:
            data = json.load(f)
        patches = data.get("patches", [])
        return {str(p["app_id"]): p for p in patches if p.get("app_id")}
    except Exception:
        return None


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
                match.type = entry.get("type", "misc")
                results.append(match)
                continue

        # 2. Fallback: bare file scan
        patch_file = _find_patch_fallback(patches_dir, game.app_id)
        if patch_file:
            match.patch_available = True
            match.patch_filename = patch_file.name
            match.patch_size = patch_file.stat().st_size

        results.append(match)

    return results


@router.get("/patches")
async def list_patches():
    patches_dir = _get_patches_dir()
    if not patches_dir.exists():
        return {"patches": [], "message": "No patches directory found"}

    index = _load_patches_index(patches_dir)
    if index:
        return {"patches": list(index.values()), "count": len(index), "source": "patches.json"}

    return {"patches": [], "count": 0, "message": "No patches.json found; run scan_patches.py to generate"}


@router.get("/patches/{app_id}/download")
async def download_patch(app_id: str):
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
                                media_type="application/octet-stream")

    # 2. Fallback
    patch_file = _find_patch_fallback(patches_dir, app_id)
    if patch_file is None:
        raise HTTPException(status_code=404, detail=f"未找到 App ID {app_id} 的补丁文件")
    return FileResponse(path=str(patch_file), filename=patch_file.name,
                        media_type="application/octet-stream")


class PatchUpdate(BaseModel):
    patch_dir: str | None = None
    target_dir: str | None = None
    label: str | None = None
    type: str | None = None


@router.put("/patches/{app_id}")
async def update_patch(app_id: str, body: PatchUpdate):
    """Update patch metadata in patches.json."""
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
        if str(p.get("app_id", "")) == app_id:
            if body.patch_dir is not None:
                p["patch_dir"] = body.patch_dir
            if body.target_dir is not None:
                p["target_dir"] = body.target_dir
            if body.label is not None:
                p["label"] = body.label
            if body.type is not None:
                p["type"] = body.type
            with open(json_path, "w", encoding="utf-8") as f:
                _json.dump(data, f, ensure_ascii=False, indent=2)
            return {"message": "已更新", "app_id": app_id}

    raise HTTPException(status_code=404, detail=f"未找到 App ID {app_id} 的补丁条目")


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
