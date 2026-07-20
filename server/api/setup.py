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
from models.file_source import FileSource, SteamPatchRoot
from models.user import User, hash_password
from services.file_source import canonical_source_path, normalize_remote_path


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
    game_libraries: list[dict] = Field(default_factory=list)
    steam_patch_libraries: list[dict] = Field(default_factory=list)


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

    async def ensure_source(item: dict) -> tuple[str, int | None, str | None, str]:
        source_type = item.get("source_type") if item.get("source_type") in {"local", "openlist"} else "local"
        path = (item.get("path") or "").strip()
        if source_type == "openlist":
            path = normalize_remote_path(path)
            source_id = item.get("source_id")
            source = None
            if source_id:
                result = await session.execute(select(FileSource).where(FileSource.id == source_id))
                source = result.scalar_one_or_none()
            if source is None:
                source = FileSource(
                    name=item.get("source_name") or item.get("name") or item.get("base_url") or "OpenList",
                    type="openlist",
                    base_url=(item.get("base_url") or "").rstrip("/"),
                    username=item.get("username") or "",
                    password=item.get("password") or "",
                )
                session.add(source)
                await session.flush()
            return source_type, source.id, source.name, path
        return "local", None, item.get("source_name"), path

    game_libraries = list(body.game_libraries)
    if not game_libraries:
        game_libraries = [{"source_type": "local", "path": p} for p in body.game_dirs]

    # Add game directories
    roots_added = 0
    for item in game_libraries:
        source_type, source_id, source_name, path = await ensure_source(item)
        if not path:
            continue
        stored_path = canonical_source_path(source_type, source_id, path)
        existing = await session.execute(
            select(RootDirectory).where(RootDirectory.path == stored_path)
        )
        if existing.scalar_one_or_none() is None:
            session.add(RootDirectory(
                path=stored_path,
                source_type=source_type,
                source_id=source_id,
                source_name=source_name,
                source_path=path,
            ))
            roots_added += 1

    patch_libraries = list(body.steam_patch_libraries)
    if not patch_libraries and body.patch_dir:
        patch_libraries = [{"source_type": "local", "path": body.patch_dir}]
    patch_roots_added = 0
    for item in patch_libraries:
        source_type, source_id, source_name, path = await ensure_source(item)
        if not path:
            continue
        session.add(SteamPatchRoot(
            source_type=source_type,
            source_id=source_id,
            source_name=source_name,
            path=path,
        ))
        patch_roots_added += 1

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
        yaml.safe_dump(config_data, f, allow_unicode=True)

    # Persist scan settings during initial setup. The normal settings endpoint
    # requires an authenticated admin, but setup runs before the first login.
    config = load_config()
    if body.patch_dir:
        config.patch_dir = body.patch_dir
    if body.steam_dir:
        config.steam_dir = body.steam_dir
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
        raise HTTPException(status_code=500, detail=f"保存自动扫描设置失败: {e}")

    await session.commit()

    # Fire background scans (don't block response — user enters main page immediately)
    asyncio.create_task(_background_scan(config))

    # Also trigger scrape on new games after scan completes
    # (handled inside _background_scan via _run_scan)

    return {
        "message": "Setup complete",
        "admin_created": True,
        "roots_added": roots_added,
        "patch_roots_added": patch_roots_added,
    }


async def _background_scan(config):
    """Run game + patch scan in background without blocking setup response."""
    logger = logging.getLogger("sena-repo")
    try:
        from api.roots import _run_scan
        stats = await _run_scan(config)
        games = stats.get("total_games", 0) if stats else 0
        logger.info(f"Background scan complete: {games} games")
    except Exception as e:
        logger.error(f"Background game scan failed: {e}\n{traceback.format_exc()}")

    try:
        import database
        from api.steam_patch import scan_patches_endpoint
        async with database._session_factory() as session:
            result = await scan_patches_endpoint(user=None, session=session)
            logger.info(f"Background patch scan complete: {result.get('scanned', 0)} files")
    except Exception as e:
        logger.error(f"Background patch scan failed: {e}\n{traceback.format_exc()}")
