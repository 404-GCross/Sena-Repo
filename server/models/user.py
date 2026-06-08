"""User model for admin/regular user authentication."""

from __future__ import annotations

import hashlib
import secrets
from datetime import datetime

from sqlalchemy import Boolean, Column, DateTime, Integer, String

from database import Base


def hash_password(password: str, salt: str | None = None) -> tuple[str, str]:
    """Hash a password with a random salt. Returns (hash, salt)."""
    if salt is None:
        salt = secrets.token_hex(16)
    h = hashlib.sha256(f"{salt}{password}".encode()).hexdigest()
    return h, salt


def verify_password(password: str, salt: str, stored_hash: str) -> bool:
    return hashlib.sha256(f"{salt}{password}".encode()).hexdigest() == stored_hash


class User(Base):
    __tablename__ = "users"

    id = Column(Integer, primary_key=True, autoincrement=True)
    username = Column(String(128), nullable=False, unique=True)
    password_hash = Column(String(128), nullable=False)
    salt = Column(String(64), nullable=False)
    is_admin = Column(Boolean, default=False)
    status = Column(String(16), default="active")  # active, pending, rejected
    created_at = Column(DateTime, default=datetime.utcnow)


class Notification(Base):
    __tablename__ = "notifications"

    id = Column(Integer, primary_key=True, autoincrement=True)
    type = Column(String(32), nullable=False)  # approval_request, approved, rejected, system
    title = Column(String(256), nullable=False)
    body = Column(String(1024), default="")
    target_user_id = Column(Integer, nullable=True)  # user being registered (for approval)
    read = Column(Boolean, default=False)
    created_at = Column(DateTime, default=datetime.utcnow)
