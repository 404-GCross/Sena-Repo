"""Common Pydantic schemas used across API routes."""

from __future__ import annotations

from pydantic import BaseModel, Field


class MessageResponse(BaseModel):
    message: str


class ErrorResponse(BaseModel):
    detail: str


class PaginatedResponse(BaseModel):
    total: int
    page: int = 1
    page_size: int = 50
