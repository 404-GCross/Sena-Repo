"""Settings API: scraper config, ignore list management."""

from __future__ import annotations

import json
from pathlib import Path

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from api.auth import get_current_user, require_admin
from config import load_config
from models.user import User

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


def _scan_settings_path(config) -> Path:
    return Path(config.data_path) / "scan_settings.json"


def _load_scan_settings(config):
    """Load persisted scan settings from JSON file."""
    path = _scan_settings_path(config)
    if path.is_file():
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            config._auto_scan = data.get("auto_scan", False)
            config._scan_interval = data.get("scan_interval", 24)
            config._scan_structure = data.get("scan_structure", "company_game")
        except Exception:
            pass


def _save_scan_settings(config):
    """Persist scan settings to JSON file."""
    path = _scan_settings_path(config)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({
        "auto_scan": getattr(config, "_auto_scan", False),
        "scan_interval": getattr(config, "_scan_interval", 24),
        "scan_structure": getattr(config, "_scan_structure", "company_game"),
    }, ensure_ascii=False, indent=2), encoding="utf-8")


@router.get("/scan", response_model=ScanSettingsOut)
async def get_scan_settings(user: User = Depends(get_current_user)):
    config = load_config()
    _load_scan_settings(config)  # restore persisted settings into memory
    return ScanSettingsOut(
        auto_scan=getattr(config, "_auto_scan", False),
        scan_interval=getattr(config, "_scan_interval", 24),
        scan_structure=getattr(config, "_scan_structure", "company_game"),
    )


@router.put("/scan")
async def update_scan_settings(body: ScanSettings, user: User = Depends(require_admin)):
    config = load_config()
    config._auto_scan = body.auto_scan
    config._scan_interval = body.scan_interval
    config._scan_structure = body.scan_structure
    _save_scan_settings(config)  # persist to disk
    return {"message": "保存成功"}


class ScraperConfigOut(BaseModel):
    bangumi_token: str = ""
    vndb_token: str = ""
    igdb_client_id: str = ""
    igdb_client_secret: str = ""
    proxy: str = ""


class ScraperConfigUpdate(BaseModel):
    bangumi_token: str | None = None
    vndb_token: str | None = None
    igdb_client_id: str | None = None
    igdb_client_secret: str | None = None
    proxy: str | None = None


@router.get("/scraper", response_model=ScraperConfigOut)
async def get_scraper_config(user: User = Depends(get_current_user)):
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
        igdb_client_id=_mask(s.igdb_client_id),
        igdb_client_secret=_mask(s.igdb_client_secret),
        proxy=config.proxy,
    )


def _scraper_config_path() -> Path:
    """Get the path to the persisted scraper config JSON file."""
    from config import load_config
    config = load_config()
    return Path(config.data_path) / "scraper_config.json"


def _read_scraper_config() -> dict:
    """Read persisted scraper config from JSON file."""
    p = _scraper_config_path()
    if p.is_file():
        try:
            import json
            return json.loads(p.read_text(encoding="utf-8"))
        except Exception:
            pass
    return {}


def _write_scraper_config(data: dict):
    """Write scraper config to JSON file."""
    _scraper_config_path().parent.mkdir(parents=True, exist_ok=True)
    import json
    p = _scraper_config_path()
    p.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")


@router.put("/scraper")
async def update_scraper_config(body: ScraperConfigUpdate, user: User = Depends(require_admin)):
    """Update scraper configuration, persisted to data directory (admin only)."""
    from config import load_config
    config = load_config()
    data = _read_scraper_config()

    for key in ("bangumi_token", "vndb_token", "igdb_client_id", "igdb_client_secret", "proxy"):
        val = getattr(body, key, None)
        if val is not None:
            setattr(config.scrapers, key, val) if key != "proxy" else setattr(config, "proxy", val)
            data[key] = val

    _write_scraper_config(data)
    return {"message": "已保存"}


@router.post("/proxy-test")
async def test_proxy(user: User = Depends(get_current_user)):
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
async def list_ignored(session: AsyncSession = Depends(get_session), user: User = Depends(get_current_user)):
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
    user: User = Depends(get_current_user),
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
