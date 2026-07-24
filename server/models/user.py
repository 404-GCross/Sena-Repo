"""User model - owner/admin/user roles."""
from __future__ import annotations
import hashlib
from datetime import datetime
import bcrypt
from sqlalchemy import Boolean, Column, DateTime, Integer, String
from database import Base


def hash_password(password: str, salt: str | None = None) -> tuple[str, str]:
    if salt is None:
        h = bcrypt.hashpw(password.encode(), bcrypt.gensalt()).decode()
        return h, "bcrypt"
    h = hashlib.sha256(f"{salt}{password}".encode()).hexdigest()
    return h, salt


def verify_password(password: str, salt: str, stored_hash: str) -> bool:
    if salt == "bcrypt":
        return bcrypt.checkpw(password.encode(), stored_hash.encode())
    return hashlib.sha256(f"{salt}{password}".encode()).hexdigest() == stored_hash


class User(Base):
    __tablename__ = "users"
    id = Column(Integer, primary_key=True, autoincrement=True)
    username = Column(String(128), nullable=False, unique=True)
    password_hash = Column(String(256), nullable=False)
    salt = Column(String(64), nullable=False)
    role = Column(String(16), default="user")   # owner | admin | user
    is_admin = Column(Boolean, default=False)   # synced with role for compat
    status = Column(String(16), default="active")   # active, pending, rejected
    token = Column(String(64), nullable=True, unique=True)
    avatar_path = Column(String(1024), nullable=True)
    created_at = Column(DateTime, default=datetime.utcnow)


class Notification(Base):
    __tablename__ = "notifications"
    id = Column(Integer, primary_key=True, autoincrement=True)
    type = Column(String(32), nullable=False)
    title = Column(String(256), nullable=False)
    body = Column(String(1024), default="")
    target_user_id = Column(Integer, nullable=True)
    read = Column(Boolean, default=False)
    created_at = Column(DateTime, default=datetime.utcnow)
