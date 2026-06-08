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

class ScanSettings(BaseModel):
    auto_scan: bool = False
    scan_interval: int = 24  # hours
    scan_structure: str = "company_game"


class ScanSettingsOut(BaseModel):
    auto_scan: bool
    scan_interval: int
    scan_structure: str


@router.get("/scan", response_model=ScanSettingsOut)
async def get_scan_settings():
    config = load_config()
    return ScanSettingsOut(
        auto_scan=getattr(config, "_auto_scan", False),
        scan_interval=getattr(config, "_scan_interval", 24),
        scan_structure=getattr(config, "_scan_structure", "company_game"),
    )


@router.put("/scan")
async def update_scan_settings(body: ScanSettings):
    config = load_config()
    config._auto_scan = body.auto_scan
    config._scan_interval = body.scan_interval
    config._scan_structure = body.scan_structure
    return {"message": "保存成功"}


class ScraperConfigOut(BaseModel):
    bangumi_token: str = ""
    vndb_token: str = ""
    steamgriddb_key: str = ""
    igdb_client_id: str = ""
    igdb_client_secret: str = ""
    proxy: str = ""


class ScraperConfigUpdate(BaseModel):
    bangumi_token: str | None = None
    vndb_token: str | None = None
    steamgriddb_key: str | None = None
    igdb_client_id: str | None = None
    igdb_client_secret: str | None = None
    proxy: str | None = None


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
        bangumi_token=_mask(s.bangumi_token),
        vndb_token=_mask(s.vndb_token),
        steamgriddb_key=_mask(s.steamgriddb_key),
        igdb_client_id=_mask(s.igdb_client_id),
        igdb_client_secret=_mask(s.igdb_client_secret),
        proxy=config.proxy,
    )


@router.put("/scraper")
async def update_scraper_config(body: ScraperConfigUpdate):
    """Update scraper configuration."""
    from config import load_config, Config
    config = load_config()
    if body.bangumi_token is not None:
        config.scrapers.bangumi_token = body.bangumi_token
    if body.vndb_token is not None:
        config.scrapers.vndb_token = body.vndb_token
    if body.steamgriddb_key is not None:
        config.scrapers.steamgriddb_key = body.steamgriddb_key
    if body.igdb_client_id is not None:
        config.scrapers.igdb_client_id = body.igdb_client_id
    if body.igdb_client_secret is not None:
        config.scrapers.igdb_client_secret = body.igdb_client_secret
    if body.proxy is not None:
        config.proxy = body.proxy
    return {"message": "已保存"}


@router.post("/proxy-test")
async def test_proxy():
    """Test if the proxy is reachable by accessing a known URL."""
    import httpx
    from config import load_config
    config = load_config()
    kwargs = {"timeout": httpx.Timeout(10.0)}
    if config.proxy:
        kwargs["proxy"] = config.proxy
    try:
        async with httpx.AsyncClient(**kwargs) as client:
            resp = await client.get("https://www.google.com")
            return {"ok": True, "status": resp.status_code, "proxy": config.proxy or "直连", "latency_ms": round(resp.elapsed.total_seconds() * 1000)}
    except Exception as e:
        return {"ok": False, "error": str(e), "proxy": config.proxy or "直连"}


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
