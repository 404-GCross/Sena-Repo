"""RootDirectory model — a top-level game storage directory."""

from __future__ import annotations

from datetime import datetime

from sqlalchemy import Column, DateTime, Boolean, Integer, String

from database import Base


class RootDirectory(Base):
    __tablename__ = "root_directories"

    id = Column(Integer, primary_key=True, autoincrement=True)
    path = Column(String(1024), nullable=False, unique=True)
    source_type = Column(String(32), nullable=False, default="local")
    source_id = Column(Integer, nullable=True)
    source_name = Column(String(255), nullable=True)
    source_path = Column(String(1024), nullable=True)
    enable_batch_scrape = Column(Boolean, default=True)
    created_at = Column(DateTime, default=datetime.utcnow)
