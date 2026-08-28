"""Hikarinagi OAuth account binding."""

from __future__ import annotations

from datetime import datetime

from sqlalchemy import Column, DateTime, ForeignKey, Integer, String, Text

from database import Base


class HikarinagiAccount(Base):
    __tablename__ = "hikarinagi_accounts"

    id = Column(Integer, primary_key=True, autoincrement=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False, index=True)
    client_id = Column(String(255), nullable=False)
    subject = Column(String(255), nullable=True)
    display_name = Column(String(255), nullable=True)
    avatar_url = Column(String(1024), nullable=True)
    scope = Column(String(1024), nullable=False, default="")
    token_type = Column(String(32), nullable=False, default="Bearer")
    access_token = Column(Text, nullable=False)
    refresh_token = Column(Text, nullable=True)
    expires_at = Column(DateTime, nullable=True)
    created_at = Column(DateTime, default=datetime.utcnow)
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)
    revoked_at = Column(DateTime, nullable=True)
