"""Root directory management API."""

from __future__ import annotations

import asyncio
import logging
import time

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy import delete, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from api.auth import get_current_user, require_admin
from config import load_config
from database import get_session
from models.game import Game, GameTag, GameVersion
from models.user import User
from models.file_source import FileSource
from models.root_directory import RootDirectory
from schemas.common import MessageResponse
from services.file_source import adapter_from_source, canonical_source_path, normalize_base_url, normalize_remote_path
from services.importer import cleanup_empty_companies, import_from_root

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/roots", tags=["roots"])
_scan_lock = asyncio.Lock()


class RootCreate(BaseModel):
    path: str = Field(min_length=1, max_length=1024)
    enable_batch_scrape: bool = True
    source_type: str = "local"
    source_id: int | None = None
    source_name: str | None = None
    base_url: str | None = None
    username: str | None = None
    password: str | None = None


class RootOut(BaseModel):
    id: int
    path: str
    source_type: str = "local"
    source_id: int | None = None
    source_name: str | None = None
    source_path: str | None = None
    enable_batch_scrape: bool

    model_config = {"from_attributes": True}


@router.get("", response_model=list[RootOut])
async def list_roots(user: User = Depends(require_admin), session: AsyncSession = Depends(get_session)):
    """List all root directories."""
    result = await session.execute(select(RootDirectory))
    return result.scalars().all()


@router.post("", response_model=RootOut, status_code=201)
async def add_root(
    body: RootCreate,
    user: User = Depends(require_admin),
    session: AsyncSession = Depends(get_session),
):
    """Add a new root directory."""
    source_type = body.source_type if body.source_type in {"local", "openlist"} else "local"
    source_id = body.source_id
    source_name = body.source_name
    source_path = body.path if source_type == "local" else normalize_remote_path(body.path)
    if source_type == "openlist":
        source = None
        if source_id:
            result = await session.execute(select(FileSource).where(FileSource.id == source_id))
            source = result.scalar_one_or_none()
            if source is None:
                raise HTTPException(status_code=404, detail="OpenList source not found")
        else:
            if not body.base_url or not body.username:
                raise HTTPException(status_code=400, detail="OpenList URL and username are required")
            source = FileSource(
                name=source_name or body.base_url,
                type="openlist",
                base_url=normalize_base_url(body.base_url),
                username=body.username,
                password=body.password or "",
            )
            session.add(source)
            await session.flush()
            source_id = source.id
        adapter = adapter_from_source(source, "openlist")
        if not await asyncio.to_thread(adapter.exists, source_path):
            raise HTTPException(status_code=404, detail="OpenList path not found")
        source_name = source.name

    stored_path = canonical_source_path(source_type, source_id, source_path)
    # Check for duplicate
    existing = await session.execute(
        select(RootDirectory).where(RootDirectory.path == stored_path)
    )
    if existing.scalar_one_or_none():
        raise HTTPException(status_code=409, detail="Root directory already exists")

    root = RootDirectory(
        path=stored_path,
        source_type=source_type,
        source_id=source_id,
        source_name=source_name,
        source_path=source_path,
        enable_batch_scrape=body.enable_batch_scrape,
    )
    session.add(root)
    await session.commit()
    await session.refresh(root)
    config = load_config()
    try:
        from api.settings import _load_scan_settings
        _load_scan_settings(config)
        if getattr(config, "_auto_scan", False):
            _bg_scan(config, [root.id], update_last=True)
    except Exception:
        logger.exception("Failed to start auto-scan for new root")
    return root


@router.put("/{root_id}", response_model=RootOut)
async def update_root(
    root_id: int,
    body: RootCreate,
    user: User = Depends(require_admin),
    session: AsyncSession = Depends(get_session),
):
    """Update a root directory without deleting the existing record."""
    result = await session.execute(select(RootDirectory).where(RootDirectory.id == root_id))
    root = result.scalar_one_or_none()
    if root is None:
        raise HTTPException(status_code=404, detail="Root directory not found")

    source_type = body.source_type if body.source_type in {"local", "openlist"} else "local"
    source_id = body.source_id
    source_name = body.source_name
    source_path = body.path if source_type == "local" else normalize_remote_path(body.path)
    if source_type == "openlist":
        source = None
        if source_id:
            result = await session.execute(select(FileSource).where(FileSource.id == source_id))
            source = result.scalar_one_or_none()
            if source is None:
                raise HTTPException(status_code=404, detail="OpenList source not found")
        else:
            if not body.base_url or not body.username:
                raise HTTPException(status_code=400, detail="OpenList source must be selected first")
            source = FileSource(
                name=source_name or body.base_url,
                type="openlist",
                base_url=normalize_base_url(body.base_url),
                username=body.username,
                password=body.password or "",
            )
            session.add(source)
            await session.flush()
            source_id = source.id
        adapter = adapter_from_source(source, "openlist")
        if not await asyncio.to_thread(adapter.exists, source_path):
            raise HTTPException(status_code=404, detail="OpenList path not found")
        source_name = source.name

    stored_path = canonical_source_path(source_type, source_id, source_path)
    existing = await session.execute(
        select(RootDirectory).where(RootDirectory.path == stored_path, RootDirectory.id != root_id)
    )
    if existing.scalar_one_or_none():
        raise HTTPException(status_code=409, detail="Root directory already exists")

    root.path = stored_path
    root.source_type = source_type
    root.source_id = source_id
    root.source_name = source_name
    root.source_path = source_path
    root.enable_batch_scrape = body.enable_batch_scrape
    await session.commit()
    await session.refresh(root)
    return root


@router.delete("/{root_id}", response_model=MessageResponse)
async def delete_root(
    root_id: int,
    user: User = Depends(require_admin),
    session: AsyncSession = Depends(get_session),
):
    """Remove a root directory (does not delete files)."""
    result = await session.execute(
        select(RootDirectory).where(RootDirectory.id == root_id)
    )
    root = result.scalar_one_or_none()
    if root is None:
        raise HTTPException(status_code=404, detail="Root directory not found")

    await session.delete(root)
    await session.commit()
    return MessageResponse(message="Root directory removed")


def _bg_scan(config, root_ids: list[int], update_last: bool = False):
    """Background scan: runs in its own async task with independent session."""
    async def _run():
        try:
            result = await _run_scan(config, root_ids=root_ids, update_last=update_last)
            if result.get("skipped"):
                logger.info("Background scan skipped: scan already running")
        except Exception:
            logger.exception("Background scan failed")
    asyncio.create_task(_run())


@router.post("/refresh-all")
async def refresh_all_roots(
    user: User = Depends(require_admin),
    session: AsyncSession = Depends(get_session),
):
    """Trigger re-scan of ALL root directories in background. Returns immediately."""
    result = await session.execute(select(RootDirectory))
    roots = result.scalars().all()
    config = load_config()
    from api.settings import _load_scan_settings
    _load_scan_settings(config)
    _bg_scan(config, [r.id for r in roots], update_last=True)
    return {"message": "扫描已在后台启动", "roots": len(roots)}


@router.post("/clear-and-refresh")
async def clear_and_refresh_roots(
    user: User = Depends(require_admin),
    session: AsyncSession = Depends(get_session),
):
    """Clear imported game library records, then re-scan all root directories."""
    if _scan_lock.locked():
        raise HTTPException(status_code=409, detail="扫描正在运行，请等待当前扫描完成后再清空重扫")

    count_result = await session.execute(select(func.count()).select_from(Game))
    cleared_games = int(count_result.scalar_one() or 0)
    await session.execute(delete(GameTag))
    await session.execute(delete(GameVersion))
    await session.execute(delete(Game))
    await cleanup_empty_companies(session)
    await session.commit()

    result = await session.execute(select(RootDirectory))
    roots = result.scalars().all()
    config = load_config()
    from api.settings import _load_scan_settings
    _load_scan_settings(config)
    _bg_scan(config, [r.id for r in roots], update_last=True)
    return {
        "message": "游戏库已清空，重新扫描已在后台启动",
        "cleared_games": cleared_games,
        "roots": len(roots),
    }


@router.post("/{root_id}/refresh")
async def refresh_root(
    root_id: int,
    user: User = Depends(require_admin),
    session: AsyncSession = Depends(get_session),
):
    """Re-scan a root directory and import/update games, then auto-scrape."""
    result = await session.execute(
        select(RootDirectory).where(RootDirectory.id == root_id)
    )
    root = result.scalar_one_or_none()
    if root is None:
        raise HTTPException(status_code=404, detail="Root directory not found")

    config = load_config()
    from api.settings import _load_scan_settings
    _load_scan_settings(config)
    _bg_scan(config, [root_id], update_last=True)
    return {"message": "扫描已在后台启动", "root_id": root_id}


async def _run_scan(config, root_ids: list[int] | None = None, update_last: bool = False):
    """Internal helper for auto-scan. Runs refresh-all without HTTP."""
    if _scan_lock.locked():
        return {"skipped": True, "reason": "scan already running"}
    import database
    from sqlalchemy import select
    from api.settings import _load_scan_settings, _mark_auto_scan
    _load_scan_settings(config)
    total_games = 0
    async with _scan_lock:
        async with database._session_factory() as session:
            query = select(RootDirectory)
            if root_ids is not None:
                query = query.where(RootDirectory.id.in_(root_ids))
            result = await session.execute(query)
            roots = result.scalars().all()
            for root in roots:
                try:
                    stats = await import_from_root(root.id, config, session)
                    total_games += stats.get("total_games", 0)
                except Exception:
                    logger.exception("Scan root %s failed", root.id)
        if update_last:
            try:
                _mark_auto_scan(config, time.time())
            except Exception:
                logger.exception("Failed to persist last auto-scan time")
        # Auto-scrape games without metadata after scan
        asyncio.create_task(_auto_scrape(config, "metadata"))
        asyncio.create_task(_auto_scrape(config, "missing"))
        return {"total_games": total_games, "roots_scanned": len(roots)}


async def _auto_scrape(config, mode: str = "missing"):
    """Background task: batch scrape games without covers or metadata."""
    import database
    from models.scrape_job import JobStatus, ScrapeJob
    from services.scraper.orchestrator import run_batch_scrape

    try:
        async with database._session_factory() as session:
            job = ScrapeJob(status=JobStatus.PENDING)
            session.add(job)
            await session.commit()
            await run_batch_scrape(config, None, session, job, mode=mode)
    except Exception:
        logger.exception("Auto-scrape failed")
