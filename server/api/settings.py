"""Settings API: scraper config, ignore list management."""

from __future__ import annotations

import json
from pathlib import Path
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from api.auth import get_current_user, require_admin
from config import (
    DEFAULT_ENABLED_SCRAPERS,
    SCRAPER_SOURCE_ORDER,
    load_config,
    normalize_scraper_config,
)
from models.user import User

from database import get_session
from models.game import Game
from models.ignore_list import IgnoreList
from schemas.common import MessageResponse
from services.scanner import normalize_game_depth, structure_from_depth

router = APIRouter(prefix="/api/settings", tags=["settings"])


# --- Scraper Config ---

class ScanSettings(BaseModel):
    auto_scan: bool = False
    scan_interval: int = Field(default=24, ge=1)  # hours
    scan_structure: str = "company_game"
    scan_depth: int | None = Field(default=None, ge=0, le=8)


class ScanSettingsOut(BaseModel):
    auto_scan: bool
    scan_interval: int
    scan_structure: str
    scan_depth: int
    last_auto_scan: float = 0


def _scan_settings_path(config) -> Path:
    return Path(config.data_path) / "scan_settings.json"


def _load_scan_settings(config):
    """Load persisted scan settings from JSON file."""
    path = _scan_settings_path(config)
    if path.is_file():
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            config._auto_scan = data.get("auto_scan", False)
            config._scan_interval = max(1, int(data.get("scan_interval", 24)))
            structure = data.get("scan_structure", "company_game")
            depth = normalize_game_depth(structure, data.get("scan_depth"))
            config._scan_depth = depth
            config._scan_structure = structure_from_depth(depth)
            config._last_auto_scan = float(data.get("last_auto_scan", 0) or 0)
        except Exception:
            pass


def _save_scan_settings(config):
    """Persist scan settings to JSON file."""
    path = _scan_settings_path(config)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({
        "auto_scan": getattr(config, "_auto_scan", False),
        "scan_interval": getattr(config, "_scan_interval", 24),
        "scan_structure": structure_from_depth(getattr(config, "_scan_depth", 2)),
        "scan_depth": getattr(config, "_scan_depth", 2),
        "last_auto_scan": getattr(config, "_last_auto_scan", 0),
    }, ensure_ascii=False, indent=2), encoding="utf-8")


def _mark_auto_scan(config, timestamp: float):
    config._last_auto_scan = timestamp
    _save_scan_settings(config)


@router.get("/scan", response_model=ScanSettingsOut)
async def get_scan_settings(user: User = Depends(get_current_user)):
    config = load_config()
    _load_scan_settings(config)  # restore persisted settings into memory
    return ScanSettingsOut(
        auto_scan=getattr(config, "_auto_scan", False),
        scan_interval=getattr(config, "_scan_interval", 24),
        scan_structure=structure_from_depth(getattr(config, "_scan_depth", 2)),
        scan_depth=getattr(config, "_scan_depth", 2),
        last_auto_scan=getattr(config, "_last_auto_scan", 0),
    )


@router.put("/scan")
async def update_scan_settings(body: ScanSettings, user: User = Depends(require_admin)):
    config = load_config()
    config._auto_scan = body.auto_scan
    config._scan_interval = body.scan_interval
    config._scan_depth = normalize_game_depth(body.scan_structure, body.scan_depth)
    config._scan_structure = structure_from_depth(config._scan_depth)
    try:
        _save_scan_settings(config)  # persist to disk
    except Exception as e:
        import logging, traceback
        logging.getLogger("sena-repo").error(f"Failed to save scan settings: {e}\n{traceback.format_exc()}")
        raise HTTPException(status_code=500, detail=f"保存失败: {e}")
    return {"message": "保存成功"}


class ScraperConfigOut(BaseModel):
    bangumi_token: str = ""
    vndb_token: str = ""
    ymgal_client_id: str = ""
    ymgal_client_secret: str = ""
    hikarinagi_client_id: str = ""
    hikarinagi_client_secret: str = ""
    hikarinagi_scope: str = "catalog:full"
    scraper_order: list[str] = Field(
        default_factory=lambda: list(SCRAPER_SOURCE_ORDER)
    )
    enabled_scrapers: list[str] = Field(
        default_factory=lambda: list(DEFAULT_ENABLED_SCRAPERS)
    )
    proxy: str = ""


class ScraperConfigUpdate(BaseModel):
    bangumi_token: str | None = None
    vndb_token: str | None = None
    ymgal_client_id: str | None = None
    ymgal_client_secret: str | None = None
    hikarinagi_client_id: str | None = None
    hikarinagi_client_secret: str | None = None
    hikarinagi_scope: str | None = None
    scraper_order: list[str] | None = None
    enabled_scrapers: list[str] | None = None
    proxy: str | None = None


class HikarinagiTestRequest(BaseModel):
    client_id: str = ""
    client_secret: str = ""
    scope: str = "catalog:full"


@router.get("/scraper", response_model=ScraperConfigOut)
async def get_scraper_config(user: User = Depends(get_current_user)):
    """Get current scraper configuration (API keys masked)."""
    from config import load_config
    config = load_config()
    normalize_scraper_config(config.scrapers)
    s = config.scrapers

    def _mask(val: str) -> str:
        if not val:
            return ""
        return val[:4] + "****" + val[-4:] if len(val) > 8 else "****"

    return ScraperConfigOut(
        bangumi_token=_mask(s.bangumi_token),
        vndb_token=_mask(s.vndb_token),
        ymgal_client_id=_mask(s.ymgal_client_id),
        ymgal_client_secret=_mask(s.ymgal_client_secret),
        hikarinagi_client_id=_mask(s.hikarinagi_client_id),
        hikarinagi_client_secret=_mask(s.hikarinagi_client_secret),
        hikarinagi_scope=s.hikarinagi_scope,
        scraper_order=s.scraper_order,
        enabled_scrapers=s.enabled_scrapers,
        proxy=_mask(config.proxy),
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

    for key in (
        "bangumi_token",
        "vndb_token",
        "ymgal_client_id",
        "ymgal_client_secret",
        "hikarinagi_client_id",
        "hikarinagi_client_secret",
        "hikarinagi_scope",
        "scraper_order",
        "enabled_scrapers",
        "proxy",
    ):
        val = getattr(body, key, None)
        if val is not None:
            if isinstance(val, str) and "****" in val:
                continue
            if isinstance(val, str):
                val = val.strip()
            if key == "hikarinagi_scope" and not val:
                val = "catalog:full"
            if key in {"scraper_order", "enabled_scrapers"}:
                if not isinstance(val, list):
                    continue
                setattr(config.scrapers, key, val)
                continue
            if key != "proxy":
                setattr(config.scrapers, key, val)
            else:
                setattr(config, "proxy", val)
            data[key] = val
    normalize_scraper_config(config.scrapers)
    data["scraper_order"] = config.scrapers.scraper_order
    data["enabled_scrapers"] = config.scrapers.enabled_scrapers
    _write_scraper_config(data)
    return {"message": "已保存"}


@router.post("/hikarinagi-test")
async def test_hikarinagi(
    body: HikarinagiTestRequest,
    user: User = Depends(require_admin),
):
    """Validate Hikarinagi OAuth credentials and catalog access without saving them."""
    import time
    import httpx
    from services.scraper.hikarinagi import HikarinagiScraper

    config = load_config()
    configured_id = config.scrapers.hikarinagi_client_id
    configured_secret = config.scrapers.hikarinagi_client_secret
    client_id = body.client_id.strip()
    client_secret = body.client_secret.strip()
    if not client_id or "****" in client_id:
        client_id = configured_id
    if not client_secret or "****" in client_secret:
        client_secret = configured_secret
    scope = body.scope.strip() or "catalog:full"
    if not client_id or not client_secret:
        return {"ok": False, "error": "请填写 Client ID 和 Client Secret"}

    client_kwargs = {"timeout": httpx.Timeout(15.0)}
    if config.proxy:
        client_kwargs["proxy"] = config.proxy
    started = time.monotonic()
    scraper = HikarinagiScraper(
        proxy=config.proxy,
        client_id=client_id,
        client_secret=client_secret,
        scope=scope,
    )
    try:
        async with httpx.AsyncClient(**client_kwargs) as client:
            await scraper._ensure_token(client)
            await scraper._api_get(
                client,
                "/api/v3/open/search",
                params=[
                    ("q", "test"),
                    ("types", "galgame"),
                    ("page", "1"),
                    ("page_size", "1"),
                ],
            )
        return {
            "ok": True,
            "scope": scope,
            "latency_ms": round((time.monotonic() - started) * 1000),
        }
    except httpx.HTTPStatusError as exc:
        return {
            "ok": False,
            "error": f"Hikarinagi 返回 HTTP {exc.response.status_code}，请检查凭据和 Scope",
        }
    except httpx.TimeoutException:
        return {"ok": False, "error": "Hikarinagi 连接超时，请检查网络或代理"}
    except Exception:
        return {"ok": False, "error": "Hikarinagi 连接失败，请检查凭据、Scope 和网络"}
    finally:
        await scraper.close()


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
    except Exception:
        return {"ok": False, "error": "代理连接失败，请检查代理地址和网络状态", "proxy": config.proxy or "直连"}


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
    user: User = Depends(require_admin),
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
