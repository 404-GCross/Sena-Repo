"""Steam patch injection API — PC client feature."""

from __future__ import annotations

import re
from pathlib import Path

from fastapi import APIRouter, HTTPException, Query
from pydantic import BaseModel

from config import load_config

router = APIRouter(prefix="/api/steam", tags=["steam-patch"])


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


class ScanRequest(BaseModel):
    """Client sends a list of installed Steam games found locally."""
    games: list[SteamGameInfo]


# ── Endpoints ──

@router.post("/scan", response_model=list[PatchMatch])
async def scan_steam_games(body: ScanRequest):
    """Client sends locally detected Steam games, server returns patch availability.

    Client should:
    1. Let user pick steamapps/common directory via file picker
    2. Read appmanifest_*.acf files to get App IDs + names
    3. POST the list to this endpoint
    """
    config = load_config()
    patches_dir = Path(config.data_path) / "steam_patches"
    results = []

    for game in body.games:
        match = PatchMatch(
            app_id=game.app_id,
            game_name=game.name,
            install_dir=game.install_dir,
            patch_available=False,
        )

        # Check if a patch exists for this App ID
        if patches_dir.exists():
            patch_file = _find_patch(patches_dir, game.app_id)
            if patch_file:
                match.patch_available = True
                match.patch_filename = patch_file.name
                match.patch_size = patch_file.stat().st_size

        results.append(match)

    return results


@router.get("/patches")
async def list_patches():
    """List all available patches on the server."""
    config = load_config()
    patches_dir = Path(config.data_path) / "steam_patches"

    if not patches_dir.exists():
        return {"patches": [], "message": "No patches directory found"}

    patches = []
    for f in sorted(patches_dir.rglob("*")):
        if f.is_file() and f.suffix.lower() in {".zip", ".rar", ".7z", ".tar", ".gz"}:
            patches.append({
                "filename": f.name,
                "path": str(f.relative_to(patches_dir)),
                "size": f.stat().st_size,
            })

    return {"patches": patches, "count": len(patches)}


def _find_patch(patches_dir: Path, app_id: str) -> Path | None:
    """Find a patch file for the given App ID in the patches directory.

    Patches are organized as: steam_patches/<app_id>/ or steam_patches/<app_id>.zip
    """
    # Direct file match: steam_patches/123456.zip
    for ext in (".zip", ".rar", ".7z", ".tar", ".gz"):
        candidate = patches_dir / f"{app_id}{ext}"
        if candidate.exists():
            return candidate

    # Directory match: steam_patches/123456/
    app_dir = patches_dir / app_id
    if app_dir.is_dir():
        for ext in (".zip", ".rar", ".7z"):
            for f in app_dir.iterdir():
                if f.is_file() and f.suffix.lower() == ext:
                    return f

    return None
