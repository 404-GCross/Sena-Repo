"""ScrapeJob model for tracking batch scraping progress."""

from __future__ import annotations

import enum
from datetime import datetime

from sqlalchemy import Column, DateTime, Enum, Integer, String, Text

from database import Base


class JobStatus(str, enum.Enum):
    PENDING = "pending"
    RUNNING = "running"
    COMPLETED = "completed"
    FAILED = "failed"


class ScrapeJob(Base):
    __tablename__ = "scrape_jobs"

    id = Column(Integer, primary_key=True, autoincrement=True)
    status = Column(Enum(JobStatus), default=JobStatus.PENDING)
    total_games = Column(Integer, default=0)
    completed_games = Column(Integer, default=0)
    failed_games = Column(Integer, default=0)
    current_game = Column(String(512), nullable=True)
    log = Column(Text, default="")
    started_at = Column(DateTime, nullable=True)
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)
    created_at = Column(DateTime, default=datetime.utcnow)
