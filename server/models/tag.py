"""Tag model and GameTag association (defined in game.py)."""

from __future__ import annotations

from datetime import datetime

from sqlalchemy import Column, DateTime, Integer, String
from sqlalchemy.orm import relationship

from database import Base


class Tag(Base):
    __tablename__ = "tags"

    id = Column(Integer, primary_key=True, autoincrement=True)
    name = Column(String(128), nullable=False, unique=True)
    color = Column(String(7), nullable=True, default="#3B82F6")  # hex color
    created_at = Column(DateTime, default=datetime.utcnow)

    games = relationship("GameTag", back_populates="tag", cascade="all, delete-orphan")
