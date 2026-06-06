"""Static file serving for covers, backgrounds, and other media."""

from __future__ import annotations

import os
from pathlib import Path

from fastapi import APIRouter, HTTPException
from fastapi.responses import FileResponse

from config import load_config

router = APIRouter(prefix="/api/files", tags=["files"])

# Allowed extensions for security
ALLOWED_EXTENSIONS = {".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp"}


@router.get("/covers/{filename:path}")
async def serve_cover(filename: str):
    """Serve a cover image file. Accepts both full path and filename only."""
    # Extract just the filename in case a full path was passed
    name = Path(filename).name
    ext = Path(name).suffix.lower()
    if ext not in ALLOWED_EXTENSIONS:
        raise HTTPException(status_code=403, detail="File type not allowed")

    config = load_config()
    file_path = config.covers_path / name

    if not file_path.is_file():
        raise HTTPException(status_code=404, detail="Cover not found")

    return FileResponse(
        file_path,
        media_type=_media_type(ext),
        headers={"Cache-Control": "public, max-age=86400"},
    )


@router.get("/backgrounds/{filename:path}")
async def serve_background(filename: str):
    """Serve a background image file. Accepts both full path and filename only."""
    name = Path(filename).name
    ext = Path(name).suffix.lower()
    if ext not in ALLOWED_EXTENSIONS:
        raise HTTPException(status_code=403, detail="File type not allowed")

    config = load_config()
    file_path = config.backgrounds_path / name

    if not file_path.is_file():
        raise HTTPException(status_code=404, detail="Background not found")

    return FileResponse(
        file_path,
        media_type=_media_type(ext),
        headers={"Cache-Control": "public, max-age=86400"},
    )


def _media_type(ext: str) -> str:
    return {
        ".jpg": "image/jpeg",
        ".jpeg": "image/jpeg",
        ".png": "image/png",
        ".gif": "image/gif",
        ".webp": "image/webp",
        ".bmp": "image/bmp",
    }.get(ext, "application/octet-stream")
