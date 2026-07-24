"""Static file serving for covers, backgrounds, and other media."""

from __future__ import annotations

import os
from pathlib import Path

import uuid

from fastapi import APIRouter, Depends, HTTPException, UploadFile, File
from pathlib import Path
from fastapi.responses import FileResponse

from api.auth import get_current_user
from config import load_config
from models.user import User

router = APIRouter(prefix="/api/files", tags=["files"])


@router.post("/upload")
async def upload_file(file: UploadFile = File(...), user: User = Depends(get_current_user)):
    """Upload an image file. Returns the filename for use in cover/bg URLs."""
    ext = Path(file.filename or "image.jpg").suffix.lower()
    if ext not in ALLOWED_EXTENSIONS:
        raise HTTPException(status_code=400, detail="File type not allowed")

    config = load_config()
    name = f"{uuid.uuid4().hex}{ext}"
    dest = config.covers_path / name
    config.covers_path.mkdir(parents=True, exist_ok=True)

    content = await file.read()
    dest.write_bytes(content)
    return {"filename": name, "url": f"/api/files/covers/{name}"}

# Allowed extensions for security
ALLOWED_EXTENSIONS = {".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp"}


@router.get("/covers/{filename:path}")
async def serve_cover(filename: str):
    """Serve a cover image file. Accepts both full path and filename only."""
    # Extract just the filename in case a full path was passed
    name = Path(filename).name
    ext = Path(name).suffix.lower()
    if ext not in ALLOWED_EXTENSIONS:
        raise HTTPException(status_code=400, detail="File type not allowed")

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
        raise HTTPException(status_code=400, detail="File type not allowed")

    config = load_config()
    file_path = config.backgrounds_path / name

    if not file_path.is_file():
        raise HTTPException(status_code=404, detail="Background not found")

    return FileResponse(
        file_path,
        media_type=_media_type(ext),
        headers={"Cache-Control": "public, max-age=86400"},
    )


@router.get("/avatars/{filename:path}")
async def serve_avatar(filename: str):
    """Serve a user avatar image file."""
    name = Path(filename).name
    ext = Path(name).suffix.lower()
    if ext not in ALLOWED_EXTENSIONS:
        raise HTTPException(status_code=400, detail="File type not allowed")

    config = load_config()
    avatars_dir = Path(config.data_path) / "avatars"
    file_path = avatars_dir / name
    if not file_path.is_file():
        raise HTTPException(status_code=404, detail="Avatar not found")
    return FileResponse(file_path, media_type=_media_type(ext),
        headers={"Cache-Control": "public, max-age=3600"})


def _media_type(ext: str) -> str:
    return {
        ".jpg": "image/jpeg",
        ".jpeg": "image/jpeg",
        ".png": "image/png",
        ".gif": "image/gif",
        ".webp": "image/webp",
        ".bmp": "image/bmp",
    }.get(ext, "application/octet-stream")
