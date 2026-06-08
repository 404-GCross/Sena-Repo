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
    created_at = Column(DateTime, default=datetime.utcnow)
