"""File source models for local and OpenList-backed libraries."""

from __future__ import annotations

from datetime import datetime

from sqlalchemy import Boolean, Column, DateTime, Integer, String, Text

from database import Base


class FileSource(Base):
    __tablename__ = "file_sources"

    id = Column(Integer, primary_key=True, autoincrement=True)
    name = Column(String(255), nullable=False)
    type = Column(String(32), nullable=False, default="local")
    base_url = Column(String(1024), nullable=True)
    username = Column(String(255), nullable=True)
    password = Column(Text, nullable=True)
    enabled = Column(Boolean, default=True)
    created_at = Column(DateTime, default=datetime.utcnow)
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)


class SteamPatchRoot(Base):
    __tablename__ = "steam_patch_roots"

    id = Column(Integer, primary_key=True, autoincrement=True)
    source_type = Column(String(32), nullable=False, default="local")
    source_id = Column(Integer, nullable=True)
    source_name = Column(String(255), nullable=True)
    path = Column(String(1024), nullable=False)
    created_at = Column(DateTime, default=datetime.utcnow)
