"""Root directory management API."""

from __future__ import annotations

import asyncio
import logging
import time

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from api.auth import get_current_user, require_admin
from config import load_config
from database import get_session
from models.user import User
from models.root_directory import RootDirectory
from schemas.common import MessageResponse
from services.importer import import_from_root

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/roots", tags=["roots"])
_scan_lock = asyncio.Lock()


class RootCreate(BaseModel):
    path: str = Field(min_length=1, max_length=1024)
    enable_batch_scrape: bool = True


class RootOut(BaseModel):
    id: int
    path: str
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
    # Check for duplicate
    existing = await session.execute(
        select(RootDirectory).where(RootDirectory.path == body.path)
    )
    if existing.scalar_one_or_none():
        raise HTTPException(status_code=409, detail="Root directory already exists")

    root = RootDirectory(path=body.path, enable_batch_scrape=body.enable_batch_scrape)
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
    _bg_scan(config, [r.id for r in roots], update_last=True)
    return {"message": "扫描已在后台启动", "roots": len(roots)}


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
    _bg_scan(config, [root_id], update_last=True)
    return {"message": "扫描已在后台启动", "root_id": root_id}


async def _run_scan(config, root_ids: list[int] | None = None, update_last: bool = False):
    """Internal helper for auto-scan. Runs refresh-all without HTTP."""
    if _scan_lock.locked():
        return {"skipped": True, "reason": "scan already running"}
    import database
    from sqlalchemy import select
    from api.settings import _mark_auto_scan
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
