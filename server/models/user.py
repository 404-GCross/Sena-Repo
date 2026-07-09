"""User model for admin/regular user authentication."""

from __future__ import annotations

import hashlib
import secrets
from datetime import datetime

import bcrypt
from sqlalchemy import Boolean, Column, DateTime, Integer, String

from database import Base


def hash_password(password: str, salt: str | None = None) -> tuple[str, str]:
    """Hash a password with bcrypt (preferred) or SHA-256 (legacy)."""
    if salt is None:
        # bcrypt: salt is embedded in the hash, use placeholder
        h = bcrypt.hashpw(password.encode(), bcrypt.gensalt()).decode()
        return h, "bcrypt"
    else:
        # Legacy SHA-256 path (migration)
        h = hashlib.sha256(f"{salt}{password}".encode()).hexdigest()
        return h, salt


def verify_password(password: str, salt: str, stored_hash: str) -> bool:
    """Verify password, supporting both bcrypt and legacy SHA-256."""
    if salt == "bcrypt":
        return bcrypt.checkpw(password.encode(), stored_hash.encode())
    else:
        return hashlib.sha256(f"{salt}{password}".encode()).hexdigest() == stored_hash


class User(Base):
    __tablename__ = "users"

    id = Column(Integer, primary_key=True, autoincrement=True)
    username = Column(String(128), nullable=False, unique=True)
    password_hash = Column(String(256), nullable=False)  # 256 for bcrypt
    salt = Column(String(64), nullable=False)
    is_admin = Column(Boolean, default=False)
    status = Column(String(16), default="active")  # active, pending, rejected
    token = Column(String(64), nullable=True, unique=True)  # random auth token
    avatar_path = Column(String(1024), nullable=True)
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
