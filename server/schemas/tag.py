"""Pydantic schemas for Tag."""

from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel, Field


class TagCreate(BaseModel):
    name: str = Field(min_length=1, max_length=128)
    color: str = Field(default="#3B82F6", max_length=7)


class TagUpdate(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=128)
    color: str | None = Field(default=None, max_length=7)


class TagOut(BaseModel):
    id: int
    name: str
    color: str | None = "#3B82F6"
    created_at: datetime

    model_config = {"from_attributes": True}
