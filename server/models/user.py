"""User model - admin/user roles."""

from __future__ import annotations

import base64
import hashlib
import hmac
import re
from datetime import datetime

import bcrypt
from sqlalchemy import (
    Boolean,
    Column,
    DateTime,
    ForeignKey,
    Integer,
    String,
    UniqueConstraint,
)

from database import Base


PASSWORD_SCHEME = "bcrypt-sha256-v1"
MAX_VERIFY_PASSWORD_BYTES = 4096


def validate_new_password(password: str) -> str:
    if not isinstance(password, str) or not 4 <= len(password) <= 128:
        raise ValueError("密码长度必须为 4–128 个字符")
    try:
        password.encode("utf-8")
    except UnicodeEncodeError:
        raise ValueError("密码包含无效字符") from None
    return password


def _password_prehash(raw: bytes) -> bytes:
    return base64.b64encode(hashlib.sha256(b"sena-password-v1\0" + raw).digest())


def hash_password(password: str, salt: str | None = None) -> tuple[str, str]:
    raw = validate_new_password(password).encode("utf-8")
    if salt is None:
        hashed = bcrypt.hashpw(_password_prehash(raw), bcrypt.gensalt()).decode("ascii")
        return hashed, PASSWORD_SCHEME
    return hashlib.sha256(salt.encode("utf-8") + raw).hexdigest(), salt


def verify_password(password: str, salt: str, stored_hash: str) -> bool:
    if not isinstance(password, str) or len(password) > MAX_VERIFY_PASSWORD_BYTES:
        return False
    if not isinstance(salt, str) or not isinstance(stored_hash, str):
        return False
    try:
        raw = password.encode("utf-8")
        if len(raw) > MAX_VERIFY_PASSWORD_BYTES:
            return False
        if salt == PASSWORD_SCHEME:
            return bcrypt.checkpw(_password_prehash(raw), stored_hash.encode("ascii"))
        if salt == "bcrypt":
            # Older bcrypt truncated at 72 bytes, including partial UTF-8 sequences.
            return bcrypt.checkpw(raw[:72], stored_hash.encode("ascii"))
        if salt.startswith("bcrypt") or len(salt) > 64 or not re.fullmatch(r"[0-9a-f]{64}", stored_hash):
            return False
        digest = hashlib.sha256(salt.encode("utf-8") + raw).hexdigest()
        return hmac.compare_digest(digest, stored_hash)
    except (UnicodeError, ValueError, TypeError):
        return False


class User(Base):
    __tablename__ = "users"

    id = Column(Integer, primary_key=True, autoincrement=True)
    username = Column(String(128), nullable=False, unique=True)
    password_hash = Column(String(256), nullable=False)
    salt = Column(String(64), nullable=False)
    role = Column(String(16), default="user")   # admin | user
    is_admin = Column(Boolean, default=False)   # synced with role for compat
    status = Column(String(16), default="active")   # active, pending, rejected
    avatar_path = Column(String(1024), nullable=True)
    oauth_provider = Column(String(32), nullable=True)
    oauth_subject = Column(String(128), nullable=True)
    oauth_name = Column(String(128), nullable=True)
    oauth_user_id = Column(Integer, nullable=True)
    password_set = Column(Boolean, default=True, nullable=False)
    created_at = Column(DateTime, default=datetime.utcnow)


class UserOAuthBinding(Base):
    __tablename__ = "user_oauth_bindings"
    __table_args__ = (
        UniqueConstraint(
            "user_id",
            "provider",
            name="uq_user_oauth_bindings_user_provider",
        ),
        UniqueConstraint(
            "provider",
            "subject",
            name="uq_user_oauth_bindings_provider_subject",
        ),
    )

    id = Column(Integer, primary_key=True, autoincrement=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False, index=True)
    provider = Column(String(32), nullable=False)
    subject = Column(String(128), nullable=True)
    name = Column(String(128), nullable=True)
    oauth_user_id = Column(Integer, nullable=True)
    access_token = Column(String(4096), nullable=True)
    refresh_token = Column(String(4096), nullable=True)
    expires_at = Column(DateTime, nullable=True)
    scope = Column(String(256), nullable=True)
    created_at = Column(DateTime, default=datetime.utcnow)
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)


class UserSession(Base):
    __tablename__ = "user_sessions"

    id = Column(Integer, primary_key=True, autoincrement=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False, index=True)
    token_hash = Column(String(64), nullable=False, unique=True, index=True)
    device_name = Column(String(256), default="")
    created_at = Column(DateTime, default=datetime.utcnow)
    last_seen_at = Column(DateTime, nullable=True)
    expires_at = Column(DateTime, nullable=False)
    revoked_at = Column(DateTime, nullable=True)
