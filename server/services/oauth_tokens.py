"""Persist and refresh provider tokens bound to a Sena account."""

from __future__ import annotations

import asyncio
import hashlib
import logging
import time
from contextlib import asynccontextmanager
from pathlib import Path
from datetime import datetime, timedelta
from typing import Awaitable, Callable

import httpx
from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import AsyncSession

from config import load_config
from models.user import UserOAuthBinding
from services.oauth_providers import OAuthProvider, provider
from utils.secrets import decrypt_secret, encrypt_secret
from utils.process_lock import process_lock

logger = logging.getLogger(__name__)

_REFRESH_SKEW = timedelta(seconds=60)
TokenProvider = Callable[[bool], Awaitable[str | None]]


class OAuthTokenError(RuntimeError):
    """Temporary token problem that can be retried later."""


class OAuthReauthRequired(OAuthTokenError):
    """Stored authorization is no longer usable; the user must authorize again."""


def validate_token_response(tokens: dict) -> None:
    if (not isinstance(tokens, dict) or not isinstance(tokens.get("access_token"), str)
            or not tokens["access_token"] or len(tokens["access_token"]) > 65536):
        raise OAuthTokenError("授权服务返回了无效的令牌响应")
    for key, limit in (("refresh_token", 65536), ("scope", 256)):
        if key in tokens and (not isinstance(tokens[key], str) or len(tokens[key]) > limit):
            raise OAuthTokenError("授权服务返回了无效的令牌响应")
    if "expires_in" in tokens:
        expires = tokens["expires_in"]
        if isinstance(expires, str) and expires.isascii() and expires.isdecimal() and len(expires) <= 8:
            expires = int(expires)
        if type(expires) is not int or not 0 < expires <= 366 * 24 * 60 * 60:
            raise OAuthTokenError("授权服务返回了无效的令牌有效期")


def save_binding_tokens(
    binding: UserOAuthBinding,
    tokens: dict,
    *,
    provider_key: str = "",
) -> None:
    """Store tokens returned by the OP encrypted at rest."""
    if not tokens:
        return
    validate_token_response(tokens)
    access = tokens["access_token"]
    refresh = tokens.get("refresh_token", "")
    expires = tokens.get("expires_in")
    expires_at = datetime.utcnow() + timedelta(seconds=int(expires)) if expires is not None else None
    binding.access_token = encrypt_secret(access)
    if refresh:
        binding.refresh_token = encrypt_secret(refresh)
    binding.expires_at = expires_at
    scope = tokens.get("scope", "").strip()
    if scope:
        binding.scope = scope
    binding.provider = provider_key or binding.provider


def _decrypt(value: str | None) -> str:
    try:
        return decrypt_secret(value)
    except RuntimeError:
        logger.warning("Stored OAuth token could not be decrypted")
        return ""


async def _refresh_tokens(
    spec: OAuthProvider,
    refresh_token: str,
) -> dict:
    payload = {
        "grant_type": "refresh_token",
        "refresh_token": refresh_token,
        "client_id": spec.client_id,
    }
    kwargs: dict = {"timeout": 20.0}
    proxy = load_config().proxy
    if proxy:
        kwargs["proxy"] = proxy
    async with httpx.AsyncClient(**kwargs) as client:
        resp = await client.post(
            spec.token_url,
            data=payload,
            headers={
                "Accept": "application/json",
                "Content-Type": "application/x-www-form-urlencoded",
            },
        )
    if resp.status_code in (400, 401, 403):
        logger.warning(
            "OAuth token refresh rejected: provider=%s status=%s",
            spec.key,
            resp.status_code,
        )
        raise OAuthReauthRequired(
            f"{spec.label} 授权已失效，请重新绑定或登录以授权目录读取"
        )
    if resp.status_code != 200:
        logger.warning(
            "OAuth token refresh failed: provider=%s status=%s",
            spec.key,
            resp.status_code,
        )
        raise OAuthTokenError(
            f"暂时无法刷新 {spec.label} 授权，请稍后重试"
        )
    try:
        data = resp.json()
    except ValueError:
        logger.warning(
            "OAuth token refresh returned invalid JSON: provider=%s", spec.key
        )
        raise OAuthTokenError(f"{spec.label} 返回了无效的授权响应")
    validate_token_response(data)
    return data


_IDENTITY_FIELDS = ("id", "user_id", "provider", "subject", "oauth_user_id", "created_at")
_TOKEN_FIELDS = ("access_token", "refresh_token", "expires_at", "scope")
_REFRESH_WAIT_SECONDS = 60.0
_REFRESH_OPERATION_SECONDS = 30.0


def _reauth(spec: OAuthProvider) -> OAuthReauthRequired:
    return OAuthReauthRequired(f"{spec.label} 授权已失效，请重新绑定或登录以授权目录读取")


async def _binding_snapshot(session: AsyncSession, user_id: int, provider_key: str) -> dict | None:
    table = UserOAuthBinding.__table__
    row = (await session.execute(select(table).where(
        table.c.user_id == user_id, table.c.provider == provider_key,
    ))).mappings().one_or_none()
    snapshot = dict(row) if row is not None else None
    # No read transaction or stale ORM identity may cross the lock/network wait.
    await session.rollback()
    return snapshot


def _same_identity(left: dict, right: dict | None) -> bool:
    return right is not None and all(left[key] == right[key] for key in _IDENTITY_FIELDS)


def _usable_access(binding: dict, *, skew: timedelta = timedelta()) -> str:
    access = _decrypt(binding["access_token"])
    expires = binding["expires_at"]
    return access if access and (expires is None or expires - skew > datetime.utcnow()) else ""


def _newer_access(original: dict, current: dict) -> str:
    if any(original[key] != current[key] for key in _TOKEN_FIELDS):
        return _usable_access(current)
    return ""


@asynccontextmanager
async def _refresh_lock(user_id: int, provider_key: str):
    stripe = hashlib.sha256(f"{user_id}:{provider_key}".encode()).digest()[0]
    path = Path(load_config().data_path or "/data") / ".oauth-refresh-locks" / f"{stripe:02x}.lock"
    deadline = time.monotonic() + _REFRESH_WAIT_SECONDS
    while True:
        try:
            with process_lock(path) as acquired:
                if acquired:
                    yield
                    return
        except OSError:
            raise OAuthTokenError("暂时无法锁定授权刷新，请稍后重试") from None
        if time.monotonic() >= deadline:
            raise OAuthTokenError("授权刷新繁忙，请稍后重试")
        await asyncio.sleep(0.05)


async def _refresh_commit_locked(session: AsyncSession, spec: OAuthProvider, original: dict) -> str:
    refresh = _decrypt(original["refresh_token"])
    try:
        tokens = await _refresh_tokens(spec, refresh)
    except (OAuthTokenError, httpx.HTTPError) as exc:
        current = await _binding_snapshot(session, original["user_id"], spec.key)
        if not _same_identity(original, current):
            raise _reauth(spec) from None
        winner = _newer_access(original, current)
        if winner:
            return winner
        if isinstance(exc, OAuthTokenError):
            raise
        logger.warning("OAuth token refresh network failure: provider=%s", spec.key)
        raise OAuthTokenError(f"暂时无法刷新 {spec.label} 授权，请稍后重试") from None

    # Encrypt on a transient object; mutating the ORM binding would autoflush before CAS.
    replacement = UserOAuthBinding(
        provider=spec.key, refresh_token=original["refresh_token"], scope=original["scope"],
    )
    save_binding_tokens(replacement, tokens, provider_key=spec.key)
    values = {key: getattr(replacement, key) for key in _TOKEN_FIELDS}
    table = UserOAuthBinding.__table__
    conditions = [table.c[key] == original[key] for key in (*_IDENTITY_FIELDS, *_TOKEN_FIELDS)]
    result = await session.execute(update(table).where(*conditions).values(**values))
    if result.rowcount == 1:
        await session.commit()
        return tokens["access_token"]
    await session.rollback()
    current = await _binding_snapshot(session, original["user_id"], spec.key)
    if not _same_identity(original, current):
        raise _reauth(spec)
    winner = _newer_access(original, current)
    if winner:
        return winner
    raise _reauth(spec)

async def _refresh_and_commit(session: AsyncSession, spec: OAuthProvider, original: dict) -> str:
    try:
        return await asyncio.wait_for(
            _refresh_commit_locked(session, spec, original), timeout=_REFRESH_OPERATION_SECONDS,
        )
    except asyncio.TimeoutError:
        await session.rollback()
        raise OAuthTokenError(f"刷新 {spec.label} 授权超时，请稍后重试") from None


async def _join_refresh(task: asyncio.Task) -> str:
    cancelled = False
    while True:
        try:
            result = await asyncio.shield(task)
            break
        except asyncio.CancelledError:
            if task.cancelled():
                raise
            cancelled = True
        except BaseException:
            if cancelled:
                raise asyncio.CancelledError() from None
            raise
    if cancelled:
        raise asyncio.CancelledError()
    return result


async def get_provider_access_token(
    session: AsyncSession, user_id: int, provider_key: str, *, force_refresh: bool = False,
) -> str | None:
    spec = provider(provider_key)
    if spec is None or not spec.enabled:
        return None
    original = await _binding_snapshot(session, user_id, spec.key)
    if original is None or not original["subject"]:
        return None
    access = _usable_access(original, skew=_REFRESH_SKEW)
    if access and not force_refresh:
        return access
    async with _refresh_lock(user_id, spec.key):
        current = await _binding_snapshot(session, user_id, spec.key)
        if not _same_identity(original, current):
            raise _reauth(spec)
        winner = _newer_access(original, current)
        if winner:
            return winner
        access = _usable_access(current, skew=_REFRESH_SKEW)
        if access and not force_refresh:
            return access
        if not _decrypt(current["refresh_token"]):
            raise _reauth(spec)
        # Once a rotating request starts, persist its result before cancellation releases this lock/session.
        task = asyncio.create_task(_refresh_and_commit(session, spec, current))
        return await _join_refresh(task)


def token_provider_for_user(
    user_id: int,
    provider_key: str = "hikarinagi",
) -> TokenProvider:
    """Build a callback that opens its own DB session for scraper use."""

    async def provide(force_refresh: bool = False) -> str | None:
        import database

        if database._session_factory is None:
            return None
        async with database._session_factory() as session:
            return await get_provider_access_token(
                session,
                user_id,
                provider_key,
                force_refresh=force_refresh,
            )

    return provide
