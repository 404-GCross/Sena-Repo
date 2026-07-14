"""Server setup wizard API."""

from __future__ import annotations

import asyncio, json, logging, traceback

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from config import load_config
from database import get_session
from models.root_directory import RootDirectory
from models.user import User, hash_password


router = APIRouter(prefix="/api/setup", tags=["setup"])


class SetupStatus(BaseModel):
    needs_setup: bool
    has_admin: bool
    has_roots: bool


class InitRequest(BaseModel):
    admin_username: str = Field(min_length=2, max_length=128)
    admin_password: str = Field(min_length=4, max_length=128)
    game_dirs: list[str] = Field(default_factory=list)  # paths to scan
    steam_dir: str = ""
    patch_dir: str = ""
    auto_scan: bool = False
    scan_interval: int = Field(default=24, ge=1)
    scan_structure: str = "company_game"


@router.get("/status", response_model=SetupStatus)
async def setup_status(session: AsyncSession = Depends(get_session)):
    """Check if server needs initial setup."""
    # Check for any admin user
    users = await session.execute(select(User).where(User.is_admin == True))
    has_admin = users.scalar_one_or_none() is not None

    # Check for any root directories
    roots = await session.execute(select(RootDirectory))
    has_roots = roots.scalar_one_or_none() is not None

    return SetupStatus(
        needs_setup=not has_admin,
        has_admin=has_admin,
        has_roots=has_roots,
    )


@router.post("/initialize")
async def initialize_setup(
    body: InitRequest,
    session: AsyncSession = Depends(get_session),
):
    """First-time setup: create admin user and initial configuration."""
    # Check if already set up
    status = await setup_status(session)
    if status.has_admin:
        raise HTTPException(status_code=400, detail="Server already initialized")

    # Create admin user
    pw_hash, salt = hash_password(body.admin_password)
    user = User(username=body.admin_username, password_hash=pw_hash, salt=salt, is_admin=True)
    session.add(user)

    # Add game directories
    roots_added = 0
    for path in body.game_dirs:
        path = path.strip()
        if not path:
            continue
        existing = await session.execute(
            select(RootDirectory).where(RootDirectory.path == path)
        )
        if existing.scalar_one_or_none() is None:
            session.add(RootDirectory(path=path))
            roots_added += 1

    await session.commit()

    # Save patch_dir and steam_dir to config.yaml
    import yaml, os
    config_path = "config.yaml"
    config_data = {}
    if os.path.isfile(config_path):
        with open(config_path, "r", encoding="utf-8") as f:
            config_data = yaml.safe_load(f) or {}
    if body.patch_dir:
        config_data["patch_dir"] = body.patch_dir
    if body.steam_dir:
        config_data["steam_dir"] = body.steam_dir
    with open(config_path, "w", encoding="utf-8") as f:
        yaml.dump(config_data, f)

    # Persist scan settings during initial setup. The normal settings endpoint
    # requires an authenticated admin, but setup runs before the first login.
    config = load_config()
    config._auto_scan = body.auto_scan
    config._scan_interval = body.scan_interval
    config._scan_structure = (
        body.scan_structure
        if body.scan_structure in {"company_game", "game_only", "flat"}
        else "company_game"
    )
    try:
        from api.settings import _save_scan_settings
        _save_scan_settings(config)
    except Exception as e:
        logger = logging.getLogger("sena-repo")
        logger.error(f"Failed to save initial scan settings: {e}\n{traceback.format_exc()}")

    # Fire background scans (don't block response — user enters main page immediately)
    asyncio.create_task(_background_scan(config, body.patch_dir))

    # Also trigger scrape on new games after scan completes
    # (handled inside _background_scan via _run_scan)

    return {
        "message": "Setup complete",
        "admin_created": True,
        "roots_added": roots_added,
    }


async def _background_scan(config, patch_dir: str):
    """Run game + patch scan in background without blocking setup response."""
    logger = logging.getLogger("sena-repo")
    try:
        from api.roots import _run_scan
        stats = await _run_scan(config)
        games = stats.get("total_games", 0) if stats else 0
        logger.info(f"Background scan complete: {games} games")
    except Exception as e:
        logger.error(f"Background game scan failed: {e}\n{traceback.format_exc()}")

    if patch_dir:
        try:
            from scan_patches import scan_patches_dir, load_existing, merge
            from pathlib import Path as _Path
            patches_dir = _Path(patch_dir)
            patches_dir.mkdir(parents=True, exist_ok=True)
            scanned = await asyncio.to_thread(scan_patches_dir, patches_dir)
            if scanned:
                json_path = patches_dir / "patches.json"
                existing = load_existing(json_path)
                existing_list = existing.get("patches", []) if existing else []
                merged_patches = merge(existing_list, scanned)
                with open(json_path, "w", encoding="utf-8") as _f:
                    json.dump({"patches": merged_patches}, _f, ensure_ascii=False, indent=2)
                logger.info(f"Background patch scan complete: {len(scanned)} files")
        except Exception as e:
            logger.error(f"Background patch scan failed: {e}\n{traceback.format_exc()}")
