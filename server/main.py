"""Sena Repo Server — FastAPI application entry point."""

from __future__ import annotations

import asyncio
import json
import logging
import time
from contextlib import asynccontextmanager
from datetime import datetime
from pathlib import Path

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from config import load_config
from database import create_tables, init_database

_initial_scan_tasks: set[asyncio.Task] = set()


async def _fail_interrupted_scrape_jobs(logger):
    from sqlalchemy import select

    from database import get_session
    from models.scrape_job import JobStatus, ScrapeJob

    async for session in get_session():
        result = await session.execute(
            select(ScrapeJob).where(
                ScrapeJob.status.in_([JobStatus.PENDING, JobStatus.RUNNING])
            )
        )
        jobs = result.scalars().all()
        now = datetime.utcnow()
        for job in jobs:
            job.status = JobStatus.FAILED
            job.current_stage = "interrupted"
            job.last_error = "服务重启或后台任务中断，已停止旧刮削任务"
            job.heartbeat_at = now
            job.log = (
                (job.log or "")
                + " [服务重启或后台任务中断，已自动停止旧刮削任务]"
            )
        if jobs:
            await session.commit()
            logger.warning("Marked %s interrupted scrape job(s) as failed", len(jobs))
        break


async def _auto_scan_task(config, logger):
    """Background task: periodically scan if auto-scan is enabled."""
    import asyncio
    while True:
        await asyncio.sleep(300)  # check every 5 minutes
        try:
            from api.settings import _load_scan_settings
            _load_scan_settings(config)
            if not getattr(config, "_auto_scan", False):
                continue
            # Check if enough time has passed since last scan
            last = getattr(config, "_last_auto_scan", 0)
            now = time.time()
            interval_seconds = getattr(config, "_scan_interval", 24) * 3600
            if now - last < interval_seconds:
                continue
            logger.info("Auto-scan triggered")
            # Run scan via the internal function
            from api.roots import _run_scan
            result = await _run_scan(config, update_last=True)
            if result.get("skipped"):
                logger.info("Auto-scan skipped: scan already running")
        except Exception as e:
            logger.error(f"Auto-scan error: {e}")


async def _auto_backup_task(config, logger):
    """Background task: run the calendar schedule configured for automatic backups."""
    from services import backup_schedule as sched

    # Give the initial library scan a head start before touching the disk.
    await asyncio.sleep(300)
    while True:
        try:
            settings = sched.load_backup_settings(config)
            if settings.get("enabled"):
                now = datetime.now()
                if not float(settings.get("next_run_at") or 0):
                    settings["next_run_at"] = sched.compute_next_run(
                        settings, now
                    ).timestamp()
                    sched.save_backup_settings(config, settings)
                elif sched.is_due(settings, now):
                    from cli.backup import run_auto_backup

                    result = await run_auto_backup(config)
                    if result.get("skipped"):
                        logger.info("Auto backup skipped: %s", result.get("skipped"))
                    else:
                        logger.info(
                            "Auto backup created: file=%s bytes=%s removed=%s games=%s",
                            result.get("file"),
                            result.get("bytes"),
                            len(result.get("removed") or []),
                            result.get("games"),
                        )
        except Exception as exc:
            logger.error(
                "Auto backup failed: %s", type(exc).__name__, exc_info=True
            )
            try:
                settings = sched.load_backup_settings(config)
                sched.save_backup_settings(
                    config,
                    sched.record_failure(
                        settings,
                        now=datetime.now(),
                        message=f"{type(exc).__name__}: {exc}",
                    ),
                )
            except Exception:
                pass
        await asyncio.sleep(60)


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Application lifespan: initialize DB on startup."""
    config = load_config()
    from utils.logging_config import configure_logging

    configure_logging("server", config.data_path)
    logger = logging.getLogger("sena-repo")
    logger.info("Starting Sena Repo server...")
    from api.settings import migrate_scraper_config_secrets

    migrate_scraper_config_secrets(config)
    init_database(config)
    await create_tables()
    await _fail_interrupted_scrape_jobs(logger)
    logger.info(f"Database initialized at: {config.database_url}")
    logger.info(f"Games path: {config.games_path}")
    logger.info(f"Data path: {config.data_path}")
    patch_index = Path(config.data_path) / "steam_patch_index" / "patches.json"
    patch_count = 0
    if patch_index.is_file():
        try:
            patch_count = len(
                json.loads(patch_index.read_text(encoding="utf-8")).get("patches", [])
            )
        except Exception as exc:
            logger.error(f"Steam patch index is unreadable: {patch_index} ({exc})")
            patch_count = -1
    logger.info(f"Steam patch index: {patch_index} ({patch_count} entries)")

    # Store config in app state for route access
    app.state.config = config

    # Auto-scan on first start if roots exist but no games yet
    try:
        from sqlalchemy import select, func
        from database import get_session as _get_session
        from models.game import Game
        from models.root_directory import RootDirectory
        async for _s in _get_session():
            root_count = (await _s.execute(select(func.count()).select_from(RootDirectory))).scalar()
            game_count = (await _s.execute(select(func.count()).select_from(Game).where(Game.is_deleted == False))).scalar()
            if root_count > 0 and game_count == 0:
                logger.info(f"Found {root_count} roots, 0 games — triggering initial scan")
                from api.roots import _run_scan

                async def _initial_scan():
                    try:
                        stats = await _run_scan(config)
                        logger.info(
                            "Initial scan complete: %s games",
                            stats.get("total_games", 0),
                        )
                    except Exception:
                        logger.exception("Initial auto-scan failed")

                task = asyncio.create_task(_initial_scan())
                _initial_scan_tasks.add(task)
                task.add_done_callback(_initial_scan_tasks.discard)
    except Exception as e:
        logger.error(f"Initial auto-scan failed: {e}", exc_info=True)

    # Restore persisted auto-scan settings before starting background task
    from api.settings import _load_scan_settings
    _load_scan_settings(config)

    # Start auto-scan background task
    task = asyncio.create_task(_auto_scan_task(config, logger))
    backup_task = asyncio.create_task(_auto_backup_task(config, logger))

    yield

    task.cancel()
    backup_task.cancel()
    try:
        await task
    except asyncio.CancelledError:
        pass
    try:
        await backup_task
    except asyncio.CancelledError:
        pass

    logger.info("Shutting down Sena Repo server...")


import os as _os

_config = load_config()

app = FastAPI(
    title="Sena Repo",
    description="GalGame Private Library Manager API",
    version=_os.environ.get("SENA_VERSION", "0.1.0"),
    lifespan=lifespan,
)

# CORS is disabled for browsers unless explicit origins are configured.
app.add_middleware(
    CORSMiddleware,
    allow_origins=_config.server.allowed_origins,
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Register API routers
from api.games import router as games_router
from api.tags import router as tags_router
from api.platforms import router as platforms_router
from api.roots import router as roots_router
from api.download import router as download_router
from api.file_sources import router as file_sources_router
from api.settings import router as settings_router
from api.scraper import router as scraper_router
from api.files import router as files_router
from api.steam_patch import router as steam_patch_router, signed_router as steam_patch_signed_router
from api.setup import router as setup_router
from api.auth import router as auth_router
from api.oauth import router as oauth_router
from api.backup import router as backup_router

app.include_router(games_router)
app.include_router(tags_router)
app.include_router(platforms_router)
app.include_router(roots_router)
# Must come before download_router: /api/download/signed/steam-patch/{key} would
# otherwise be captured by /api/download/signed/{game_id}/{version_id}.
app.include_router(steam_patch_signed_router)
app.include_router(download_router)
app.include_router(file_sources_router)
app.include_router(settings_router)
app.include_router(scraper_router)
app.include_router(files_router)
app.include_router(steam_patch_router)
app.include_router(setup_router)
app.include_router(auth_router)
app.include_router(oauth_router)
app.include_router(backup_router)


@app.get("/api/health")
async def health_check():
    """Health check endpoint."""
    return {"status": "ok", "version": _os.environ.get("SENA_VERSION", "0.1.0")}


if __name__ == "__main__":
    import uvicorn
    config = load_config()
    uvicorn.run(
        "main:app",
        host=config.server.host,
        port=config.server.port,
        reload=True,
    )
