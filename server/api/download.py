"""Streaming file download API."""

from __future__ import annotations

from pathlib import Path

from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import StreamingResponse
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from database import get_session
from models.game import Game, GameVersion

router = APIRouter(prefix="/api/download", tags=["download"])

CHUNK_SIZE = 1024 * 1024  # 1MB chunks


@router.get("/{game_id}/{version_id}")
async def download_game_version(
    game_id: int,
    version_id: int,
    session: AsyncSession = Depends(get_session),
):
    """Download a specific game version archive file."""
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

    file_path = Path(version.file_path)
    if not file_path.is_file():
        raise HTTPException(status_code=404, detail="File not found on server")

    file_size = file_path.stat().st_size

    async def file_stream():
        with open(file_path, "rb") as f:
            while chunk := f.read(CHUNK_SIZE):
                yield chunk

    return StreamingResponse(
        file_stream(),
        media_type="application/octet-stream",
        headers={
            "Content-Disposition": f'attachment; filename="{version.filename}"',
            "Content-Length": str(file_size),
        },
    )
