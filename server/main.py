"""Sena Repo Server — FastAPI application entry point."""

from __future__ import annotations

import asyncio
import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from config import load_config
from database import create_tables, init_database


async def _auto_scan_task(config, logger):
    """Background task: periodically scan if auto-scan is enabled."""
    import asyncio
    while True:
        await asyncio.sleep(300)  # check every 5 minutes
        try:
            if not getattr(config, "_auto_scan", False):
                continue
            # Check if enough time has passed since last scan
            last = getattr(config, "_last_auto_scan", 0)
            now = asyncio.get_event_loop().time()
            interval_seconds = getattr(config, "_scan_interval", 24) * 3600
            if now - last < interval_seconds:
                continue
            logger.info("Auto-scan triggered")
            # Run scan via the internal function
            from api.roots import _run_scan
            await _run_scan(config)
            config._last_auto_scan = now
        except Exception as e:
            logger.error(f"Auto-scan error: {e}")


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Application lifespan: initialize DB on startup."""
    logging.basicConfig(level=logging.INFO)
    logger = logging.getLogger("sena-repo")
    logger.info("Starting Sena Repo server...")

    config = load_config()
    init_database(config)
    await create_tables()
    logger.info(f"Database initialized at: {config.database_url}")
    logger.info(f"Games path: {config.games_path}")
    logger.info(f"Data path: {config.data_path}")

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
                stats = await _run_scan(config)
                logger.info(f"Initial scan complete: {stats.get('total_games', 0)} games")
    except Exception as e:
        logger.error(f"Initial auto-scan failed: {e}", exc_info=True)

    # Restore persisted auto-scan settings before starting background task
    from api.settings import _load_scan_settings
    _load_scan_settings(config)

    # Start auto-scan background task
    task = asyncio.create_task(_auto_scan_task(config, logger))

    yield

    task.cancel()
    try:
        await task
    except asyncio.CancelledError:
        pass

    logger.info("Shutting down Sena Repo server...")


import os as _os

app = FastAPI(
    title="Sena Repo",
    description="GalGame Private Library Manager API",
    version=_os.environ.get("SENA_VERSION", "0.1.0"),
    lifespan=lifespan,
)

# CORS — allow all origins for LAN/home server use
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Register API routers
from api.games import router as games_router
from api.tags import router as tags_router
from api.roots import router as roots_router
from api.download import router as download_router
from api.settings import router as settings_router
from api.scraper import router as scraper_router
from api.files import router as files_router
from api.steam_patch import router as steam_patch_router
from api.setup import router as setup_router
from api.auth import router as auth_router

app.include_router(games_router)
app.include_router(tags_router)
app.include_router(roots_router)
app.include_router(download_router)
app.include_router(settings_router)
app.include_router(scraper_router)
app.include_router(files_router)
app.include_router(steam_patch_router)
app.include_router(setup_router)
app.include_router(auth_router)


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
