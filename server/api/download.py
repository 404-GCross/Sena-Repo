"""File download API — uses FileResponse for reliable async file serving."""

from __future__ import annotations

import asyncio
import logging
from pathlib import Path

from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import FileResponse, RedirectResponse
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from api.auth import get_current_user
from config import load_config
from database import get_session
from models.game import Game, GameVersion
from models.file_source import FileSource
from models.user import User
from services.file_source import adapter_from_source

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/download", tags=["download"])


@router.get("/{game_id}/{version_id}")
async def download_game_version(
    game_id: int,
    version_id: int,
    user: User = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
):
    """Download a specific game version archive file.

    Uses FileResponse which handles:
    - Non-blocking async file I/O via thread pool
    - Content-Length, Content-Disposition, ETag
    - Range requests (resumable downloads) automatically
    - UTF-8 filenames with RFC 5987 encoding
    """
    try:
        # Verify game exists and is not deleted
        result = await session.execute(
            select(Game).where(Game.id == game_id, Game.is_deleted == False)
        )
        game = result.scalar_one_or_none()
        if game is None:
            raise HTTPException(status_code=404, detail="Game not found")

        # Get version
        result = await session.execute(
            select(GameVersion).where(
                GameVersion.id == version_id,
                GameVersion.game_id == game_id,
            )
        )
        version = result.scalar_one_or_none()
        if version is None:
            raise HTTPException(status_code=404, detail="Version not found")

        if (version.source_type or "local") == "openlist":
            result = await session.execute(select(FileSource).where(FileSource.id == version.source_id))
            source = result.scalar_one_or_none()
            adapter = adapter_from_source(source, "openlist")
            raw_url = await asyncio.to_thread(adapter.download_url, version.source_path or version.file_path)
            return RedirectResponse(raw_url, status_code=302)

        file_path = Path(version.file_path).resolve()
        # Verify file is within configured games directory
        config = load_config()
        games_root = Path(config.games_path).resolve()
        try:
            file_path.relative_to(games_root)
        except ValueError:
            raise HTTPException(status_code=403, detail="File outside games directory")

        if not file_path.is_file():
            raise HTTPException(status_code=404, detail="File not found")

        return FileResponse(
            path=str(file_path),
            filename=version.filename,
            media_type="application/octet-stream",
        )
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Download failed gid={game_id} vid={version_id}: {e}")
        raise HTTPException(status_code=500, detail="下载失败，请查看服务端日志")
