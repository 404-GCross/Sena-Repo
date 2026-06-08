"""Sena Repo Server — FastAPI application entry point."""

from __future__ import annotations

import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from config import load_config
from database import create_tables, init_database


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

    yield

    logger.info("Shutting down Sena Repo server...")


app = FastAPI(
    title="Sena Repo",
    description="GalGame Private Library Manager API",
    version="0.1.0",
    lifespan=lifespan,
)

# CORS — allow all origins for LAN/home server use
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
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

app.include_router(games_router)
app.include_router(tags_router)
app.include_router(roots_router)
app.include_router(download_router)
app.include_router(settings_router)
app.include_router(scraper_router)
app.include_router(files_router)
app.include_router(steam_patch_router)
app.include_router(setup_router)


@app.get("/api/health")
async def health_check():
    """Health check endpoint."""
    return {"status": "ok", "version": "0.1.0"}


if __name__ == "__main__":
    import uvicorn
    config = load_config()
    uvicorn.run(
        "main:app",
        host=config.server.host,
        port=config.server.port,
        reload=True,
    )
