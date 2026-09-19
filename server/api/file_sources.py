"""File source management API."""

from __future__ import annotations

import asyncio
import logging

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from api.auth import require_admin
from database import get_session
from models.file_source import FileSource
from models.user import User
from services.file_source import adapter_from_source, normalize_base_url, normalize_remote_path
from utils.secrets import encrypt_secret, redact_url

router = APIRouter(prefix="/api/file-sources", tags=["file-sources"])

logger = logging.getLogger(__name__)


class FileSourceCreate(BaseModel):
    name: str = Field(min_length=1, max_length=255)
    type: str = "openlist"
    base_url: str | None = None
    username: str | None = None
    password: str | None = None


class FileSourceOut(BaseModel):
    id: int
    name: str
    type: str
    base_url: str | None = None
    username: str | None = None
    enabled: bool = True

    model_config = {"from_attributes": True}


class SourceTestBody(BaseModel):
    source_id: int | None = None
    name: str | None = None
    type: str = "openlist"
    base_url: str | None = None
    username: str | None = None
    password: str | None = None
    path: str = "/"


@router.get("", response_model=list[FileSourceOut])
async def list_sources(user: User = Depends(require_admin), session: AsyncSession = Depends(get_session)):
    result = await session.execute(select(FileSource).order_by(FileSource.id))
    return result.scalars().all()


@router.post("", response_model=FileSourceOut, status_code=201)
async def create_source(
    body: FileSourceCreate,
    user: User = Depends(require_admin),
    session: AsyncSession = Depends(get_session),
):
    if body.type != "openlist":
        raise HTTPException(status_code=400, detail="Only OpenList sources can be saved here")
    if not body.base_url:
        raise HTTPException(status_code=400, detail="OpenList URL is required")
    source = FileSource(
        name=body.name,
        type="openlist",
        base_url=normalize_base_url(body.base_url),
        username=body.username,
        password=encrypt_secret(body.password),
    )
    adapter = adapter_from_source(source, source.type)
    try:
        await asyncio.to_thread(adapter.list, "/")
    except Exception as exc:
        logger.warning(
            "File source probe failed on create: actor_id=%s base_url=%s error=%s",
            user.id,
            redact_url(source.base_url),
            type(exc).__name__,
        )
        raise
    session.add(source)
    await session.commit()
    await session.refresh(source)
    logger.info(
        "File source created: actor_id=%s source_id=%s name=%s base_url=%s username_set=%s",
        user.id,
        source.id,
        source.name,
        redact_url(source.base_url),
        bool(source.username),
    )
    return source


@router.put("/{source_id}", response_model=FileSourceOut)
async def update_source(
    source_id: int,
    body: FileSourceCreate,
    user: User = Depends(require_admin),
    session: AsyncSession = Depends(get_session),
):
    result = await session.execute(select(FileSource).where(FileSource.id == source_id))
    source = result.scalar_one_or_none()
    if source is None:
        raise HTTPException(status_code=404, detail="File source not found")
    if body.type != "openlist":
        raise HTTPException(status_code=400, detail="Only OpenList sources can be saved here")
    if not body.base_url:
        raise HTTPException(status_code=400, detail="OpenList URL is required")

    source.name = body.name
    source.type = "openlist"
    source.base_url = normalize_base_url(body.base_url)
    source.username = body.username
    if body.password is not None:
        source.password = encrypt_secret(body.password)
    adapter = adapter_from_source(source, source.type)
    try:
        await asyncio.to_thread(adapter.list, "/")
    except Exception as exc:
        logger.warning(
            "File source probe failed on update: actor_id=%s source_id=%s base_url=%s error=%s",
            user.id,
            source_id,
            redact_url(source.base_url),
            type(exc).__name__,
        )
        raise
    await session.commit()
    await session.refresh(source)
    logger.info(
        "File source updated: actor_id=%s source_id=%s name=%s base_url=%s username_set=%s password_changed=%s",
        user.id,
        source.id,
        source.name,
        redact_url(source.base_url),
        bool(source.username),
        body.password is not None,
    )
    return source


@router.post("/test")
async def test_source(
    body: SourceTestBody,
    user: User = Depends(require_admin),
    session: AsyncSession = Depends(get_session),
):
    source = None
    if body.source_id:
        result = await session.execute(select(FileSource).where(FileSource.id == body.source_id))
        source = result.scalar_one_or_none()
        if source is None:
            raise HTTPException(status_code=404, detail="File source not found")
    else:
        source = FileSource(
            name=body.name or body.base_url or "OpenList",
            type="openlist",
            base_url=normalize_base_url(body.base_url),
            username=body.username or "",
            password=body.password or "",
        )
    adapter = adapter_from_source(source, source.type)
    path = normalize_remote_path(body.path)
    try:
        entries = await asyncio.to_thread(adapter.list, path)
    except Exception as exc:
        logger.warning(
            "File source test failed: actor_id=%s source_id=%s base_url=%s path=%s error=%s",
            user.id,
            source.id if body.source_id else None,
            redact_url(source.base_url),
            path,
            type(exc).__name__,
        )
        raise
    logger.info(
        "File source test succeeded: actor_id=%s source_id=%s base_url=%s path=%s entries=%s",
        user.id,
        source.id if body.source_id else None,
        redact_url(source.base_url),
        path,
        len(entries),
    )
    return {
        "message": "连接成功",
        "path": path,
        "count": len(entries),
        "entries": [{"name": e.name, "path": e.path, "is_dir": e.is_dir, "size": e.size} for e in entries[:50]],
    }
