"""IgnoreList model — paths excluded from scanning."""

from __future__ import annotations

from datetime import datetime

from sqlalchemy import Column, DateTime, Integer, String

from database import Base


class IgnoreList(Base):
    __tablename__ = "ignore_list"

    id = Column(Integer, primary_key=True, autoincrement=True)
    path = Column(String(1024), nullable=False, unique=True)
    deleted_at = Column(DateTime, default=datetime.utcnow)
