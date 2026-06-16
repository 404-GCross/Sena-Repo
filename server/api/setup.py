"""Server setup wizard API."""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

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

    return {
        "message": "Setup complete",
        "admin_created": True,
        "roots_added": roots_added,
    }
