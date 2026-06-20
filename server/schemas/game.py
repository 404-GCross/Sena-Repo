"""Pydantic schemas for Game and related entities."""

from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel, Field


class GameVersionOut(BaseModel):
    id: int
    platform: str
    filename: str
    file_path: str
    file_size: int

    model_config = {"from_attributes": True}


class GameSummary(BaseModel):
    """Game in list view (no versions)."""
    id: int
    name: str
    company_name: str | None = None
    developer: str | None = None
    folder_path: str
    cover_path: str | None = None
    platform_summary: str = ""  # e.g. "PC, KRKR"
    tag_names: list[str] = []
    imported_at: datetime
    length: int = 0
    length_minutes: int = 0

    model_config = {"from_attributes": True}


class GameDetail(BaseModel):
    """Game in detail view (with versions and full metadata)."""
    id: int
    name: str
    company_name: str | None = None
    root_id: int
    folder_path: str
    cover_path: str | None = None
    bg_path: str | None = None
    developer: str | None = None
    description: str | None = None
    release_date: str | None = None
    vndb_id: str | None = None
    steam_id: str | None = None
    bangumi_id: str | None = None
    length: int = 0
    length_minutes: int = 0
    is_deleted: bool
    imported_at: datetime
    updated_at: datetime
    versions: list[GameVersionOut] = []
    tags: list["TagOut"] = []

    model_config = {"from_attributes": True}


class GameSearchParams(BaseModel):
    q: str | None = None
    tag: str | None = None
    platform: str | None = None
    root_id: int | None = None
    page: int = Field(default=1, ge=1)
    page_size: int = Field(default=50, ge=1, le=200)


# Nested TagOut for GameDetail
from schemas.tag import TagOut  # noqa: E402
