"""File download API — uses FileResponse for reliable async file serving."""

from __future__ import annotations

import asyncio
import logging
from pathlib import Path
from urllib.parse import quote

import httpx
from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import FileResponse, StreamingResponse
from starlette.background import BackgroundTask
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from api.auth import get_current_user
from config import load_config
from database import get_session
from models.game import Game, GameVersion
from models.file_source import FileSource
from models.root_directory import RootDirectory
from models.user import User
from services.file_source import adapter_from_source

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/download", tags=["download"])


@router.get("/{game_id}/{version_id}")
async def download_game_version(
    game_id: int,
    version_id: int,
    request: Request,
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
            return await _proxy_remote_download(raw_url, version.filename, request)

        file_path = Path(version.file_path).resolve()
        if not await _is_allowed_local_file(file_path, session):
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


async def _is_allowed_local_file(file_path: Path, session: AsyncSession) -> bool:
    """Allow local downloads only from configured local roots or legacy games_path."""
    roots: list[Path] = []
    result = await session.execute(
        select(RootDirectory).where(RootDirectory.source_type == "local")
    )
    for root in result.scalars().all():
        root_path = root.source_path or root.path
        if root_path:
            roots.append(Path(root_path).resolve())

    config = load_config()
    roots.append(Path(config.games_path).resolve())

    for root in roots:
        try:
            file_path.relative_to(root)
            return True
        except ValueError:
            continue
    return False


async def _proxy_remote_download(raw_url: str, filename: str, request: Request) -> StreamingResponse:
    """Proxy OpenList direct links so signed or IP-bound links remain usable."""
    headers = {}
    range_header = request.headers.get("range")
    if range_header:
        headers["Range"] = range_header

    client = httpx.AsyncClient(timeout=httpx.Timeout(None, connect=20.0), follow_redirects=True)
    upstream = None
    try:
        upstream = await client.send(client.build_request("GET", raw_url, headers=headers), stream=True)
        if upstream.status_code not in (200, 206):
            body = await upstream.aread()
            detail = body[:200].decode("utf-8", "ignore") if body else f"HTTP {upstream.status_code}"
            raise HTTPException(status_code=upstream.status_code, detail=detail)

        safe_name = filename.encode("ascii", "ignore").decode("ascii") or "download"
        response_headers = {
            "Content-Disposition": f"attachment; filename=\"{safe_name}\"; filename*=UTF-8''{quote(filename)}"
        }
        for key in ("content-length", "content-range", "accept-ranges", "content-type"):
            value = upstream.headers.get(key)
            if value:
                response_headers[key] = value

        async def body_iter():
            async for chunk in upstream.aiter_bytes():
                yield chunk

        async def close_upstream():
            await upstream.aclose()
            await client.aclose()

        return StreamingResponse(
            body_iter(),
            status_code=upstream.status_code,
            headers=response_headers,
            background=BackgroundTask(close_upstream),
        )
    except HTTPException:
        if upstream is not None:
            await upstream.aclose()
        await client.aclose()
        raise
    except httpx.HTTPError as exc:
        if upstream is not None:
            await upstream.aclose()
        await client.aclose()
        raise HTTPException(status_code=502, detail=f"OpenList download failed: {exc}") from exc
