"""File source management API."""

from __future__ import annotations

import asyncio

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from api.auth import require_admin
from database import get_session
from models.file_source import FileSource
from models.user import User
from services.file_source import adapter_from_source, normalize_remote_path

router = APIRouter(prefix="/api/file-sources", tags=["file-sources"])


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
    if not body.base_url or not body.username:
        raise HTTPException(status_code=400, detail="OpenList URL and username are required")
    source = FileSource(
        name=body.name,
        type="openlist",
        base_url=body.base_url.rstrip("/"),
        username=body.username,
        password=body.password or "",
    )
    adapter = adapter_from_source(source, source.type)
    await asyncio.to_thread(adapter.list, "/")
    session.add(source)
    await session.commit()
    await session.refresh(source)
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
    if not body.base_url or not body.username:
        raise HTTPException(status_code=400, detail="OpenList URL and username are required")

    source.name = body.name
    source.type = "openlist"
    source.base_url = body.base_url.rstrip("/")
    source.username = body.username
    if body.password is not None:
        source.password = body.password
    adapter = adapter_from_source(source, source.type)
    await asyncio.to_thread(adapter.list, "/")
    await session.commit()
    await session.refresh(source)
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
            base_url=(body.base_url or "").rstrip("/"),
            username=body.username or "",
            password=body.password or "",
        )
    adapter = adapter_from_source(source, source.type)
    path = normalize_remote_path(body.path)
    entries = await asyncio.to_thread(adapter.list, path)
    return {
        "message": "连接成功",
        "path": path,
        "count": len(entries),
        "entries": [{"name": e.name, "path": e.path, "is_dir": e.is_dir, "size": e.size} for e in entries[:50]],
    }
