"""Root directory management API."""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from config import load_config
from database import get_session
from models.root_directory import RootDirectory
from schemas.common import MessageResponse
from services.importer import import_from_root

router = APIRouter(prefix="/api/roots", tags=["roots"])


class RootCreate(BaseModel):
    path: str = Field(min_length=1, max_length=1024)
    enable_batch_scrape: bool = True


class RootOut(BaseModel):
    id: int
    path: str
    enable_batch_scrape: bool

    model_config = {"from_attributes": True}


@router.get("", response_model=list[RootOut])
async def list_roots(session: AsyncSession = Depends(get_session)):
    """List all root directories."""
    result = await session.execute(select(RootDirectory))
    return result.scalars().all()


@router.post("", response_model=RootOut, status_code=201)
async def add_root(
    body: RootCreate,
    session: AsyncSession = Depends(get_session),
):
    """Add a new root directory."""
    # Check for duplicate
    existing = await session.execute(
        select(RootDirectory).where(RootDirectory.path == body.path)
    )
    if existing.scalar_one_or_none():
        raise HTTPException(status_code=409, detail="Root directory already exists")

    root = RootDirectory(path=body.path, enable_batch_scrape=body.enable_batch_scrape)
    session.add(root)
    await session.commit()
    await session.refresh(root)
    return root


@router.delete("/{root_id}", response_model=MessageResponse)
async def delete_root(
    root_id: int,
    session: AsyncSession = Depends(get_session),
):
    """Remove a root directory (does not delete files)."""
    result = await session.execute(
        select(RootDirectory).where(RootDirectory.id == root_id)
    )
    root = result.scalar_one_or_none()
    if root is None:
        raise HTTPException(status_code=404, detail="Root directory not found")

    await session.delete(root)
    await session.commit()
    return MessageResponse(message="Root directory removed")


@router.post("/{root_id}/refresh", response_model=dict)
async def refresh_root(
    root_id: int,
    session: AsyncSession = Depends(get_session),
):
    """Re-scan a root directory and import/update games."""
    result = await session.execute(
        select(RootDirectory).where(RootDirectory.id == root_id)
    )
    root = result.scalar_one_or_none()
    if root is None:
        raise HTTPException(status_code=404, detail="Root directory not found")

    config = load_config()
    stats = await import_from_root(root_id, config, session)
    return stats
