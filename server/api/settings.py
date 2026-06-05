"""Settings API: scraper config, ignore list management."""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from database import get_session
from models.game import Game
from models.ignore_list import IgnoreList
from schemas.common import MessageResponse

router = APIRouter(prefix="/api/settings", tags=["settings"])


# --- Scraper Config ---

class ScraperConfigOut(BaseModel):
    vndb_token: str = ""
    steamgriddb_key: str = ""
    igdb_client_id: str = ""
    igdb_client_secret: str = ""


class ScraperConfigUpdate(BaseModel):
    vndb_token: str | None = None
    steamgriddb_key: str | None = None
    igdb_client_id: str | None = None
    igdb_client_secret: str | None = None


@router.get("/scraper", response_model=ScraperConfigOut)
async def get_scraper_config():
    """Get current scraper configuration (API keys masked)."""
    from config import load_config
    config = load_config()
    s = config.scrapers

    def _mask(val: str) -> str:
        if not val:
            return ""
        return val[:4] + "****" + val[-4:] if len(val) > 8 else "****"

    return ScraperConfigOut(
        vndb_token=_mask(s.vndb_token),
        steamgriddb_key=_mask(s.steamgriddb_key),
        igdb_client_id=_mask(s.igdb_client_id),
        igdb_client_secret=_mask(s.igdb_client_secret),
    )


# NOTE: Full scraper config update will be implemented in Phase 2
# when scraper services are built out.


# --- Ignore List ---

class IgnoreItemOut(BaseModel):
    id: int
    path: str
    deleted_at: str

    model_config = {"from_attributes": True}


@router.get("/ignore-list", response_model=list[IgnoreItemOut])
async def list_ignored(session: AsyncSession = Depends(get_session)):
    """List all ignored/deleted game paths."""
    result = await session.execute(select(IgnoreList).order_by(IgnoreList.deleted_at.desc()))
    items = result.scalars().all()
    return [
        IgnoreItemOut(
            id=item.id,
            path=item.path,
            deleted_at=item.deleted_at.isoformat(),
        )
        for item in items
    ]


@router.post("/ignore-list/{ignore_id}/restore", response_model=MessageResponse)
async def restore_from_ignore(
    ignore_id: int,
    session: AsyncSession = Depends(get_session),
):
    """Restore a game from the ignore list (un-delete it)."""
    result = await session.execute(
        select(IgnoreList).where(IgnoreList.id == ignore_id)
    )
    item = result.scalar_one_or_none()
    if item is None:
        raise HTTPException(status_code=404, detail="Ignore entry not found")

    path = item.path

    # Undelete the game
    game_result = await session.execute(
        select(Game).where(Game.folder_path == path, Game.is_deleted == True)
    )
    game = game_result.scalar_one_or_none()
    if game:
        game.is_deleted = False

    # Remove from ignore list
    await session.delete(item)
    await session.commit()

    return MessageResponse(message=f"Restored game at: {path}")
