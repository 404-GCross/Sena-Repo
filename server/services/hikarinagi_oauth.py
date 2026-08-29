"""Hikarinagi OAuth helpers for native/public app authentication."""

from __future__ import annotations

import base64
import hashlib
import json
import secrets
import threading
import time
from datetime import datetime, timedelta
from typing import Any
from urllib.parse import urlencode

import httpx
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from config import (
    DEFAULT_HIKARINAGI_REDIRECT_URI,
    DEFAULT_HIKARINAGI_SCOPE,
    load_config,
)
from models.hikarinagi import HikarinagiAccount
from utils.secrets import decrypt_secret, encrypt_secret

HIKARINAGI_AUTH_URL = "https://id.hikarinagi.org/oidc/auth"
HIKARINAGI_TOKEN_URL = "https://id.hikarinagi.org/oidc/token"

_PENDING_AUTH_TTL_SECONDS = 10 * 60
_pending_lock = threading.Lock()
_pending_auth: dict[str, dict[str, Any]] = {}


def _now() -> datetime:
    return datetime.utcnow()


def configured_redirect_uri() -> str:
    value = load_config().scrapers.hikarinagi_redirect_uri.strip()
    return value or DEFAULT_HIKARINAGI_REDIRECT_URI


def configured_scope() -> str:
    value = load_config().scrapers.hikarinagi_scope.strip()
    return value or DEFAULT_HIKARINAGI_SCOPE


def _b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


def _code_challenge(verifier: str) -> str:
    return _b64url(hashlib.sha256(verifier.encode("ascii")).digest())


def _prune_pending_auth() -> None:
    now = time.monotonic()
    expired = [
        state
        for state, item in _pending_auth.items()
        if now - float(item.get("created_at", 0.0)) > _PENDING_AUTH_TTL_SECONDS
    ]
    for state in expired:
        _pending_auth.pop(state, None)


def create_authorization_url(
    *,
    user_id: int,
    client_id: str,
    scope: str,
    redirect_uri: str,
) -> tuple[str, str]:
    state = secrets.token_urlsafe(32)
    verifier = _b64url(secrets.token_bytes(48))
    with _pending_lock:
        _prune_pending_auth()
        _pending_auth[state] = {
            "user_id": user_id,
            "client_id": client_id,
            "scope": scope,
            "redirect_uri": redirect_uri,
            "code_verifier": verifier,
            "created_at": time.monotonic(),
        }
    params = {
        "response_type": "code",
        "client_id": client_id,
        "redirect_uri": redirect_uri,
        "scope": scope,
        "state": state,
        "code_challenge": _code_challenge(verifier),
        "code_challenge_method": "S256",
        "prompt": "consent",
    }
    return f"{HIKARINAGI_AUTH_URL}?{urlencode(params)}", state


def consume_pending_auth(state: str, user_id: int) -> dict[str, Any]:
    with _pending_lock:
        _prune_pending_auth()
        item = _pending_auth.pop(state, None)
    if item is None:
        raise RuntimeError("Hikarinagi 授权会话已过期，请重新绑定")
    if int(item.get("user_id") or 0) != user_id:
        raise RuntimeError("Hikarinagi 授权会话不匹配，请重新绑定")
    return item


async def exchange_authorization_code(
    client: httpx.AsyncClient,
    *,
    client_id: str,
    code: str,
    code_verifier: str,
    redirect_uri: str,
) -> dict[str, Any]:
    resp = await client.post(
        HIKARINAGI_TOKEN_URL,
        data={
            "grant_type": "authorization_code",
            "client_id": client_id,
            "code": code,
            "code_verifier": code_verifier,
            "redirect_uri": redirect_uri,
        },
        headers={
            "Accept": "application/json",
            "Content-Type": "application/x-www-form-urlencoded",
        },
    )
    resp.raise_for_status()
    payload = resp.json()
    if not isinstance(payload, dict) or not payload.get("access_token"):
        raise RuntimeError("Hikarinagi Token 响应为空")
    return payload


def _decode_id_token(id_token: str) -> dict[str, Any]:
    parts = (id_token or "").split(".")
    if len(parts) < 2:
        return {}
    try:
        payload = parts[1] + "=" * (-len(parts[1]) % 4)
        data = json.loads(base64.urlsafe_b64decode(payload.encode("ascii")))
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def _expires_at(payload: dict[str, Any]) -> datetime | None:
    try:
        expires_in = int(payload.get("expires_in") or 0)
    except (TypeError, ValueError):
        expires_in = 0
    if expires_in <= 0:
        return None
    return _now() + timedelta(seconds=expires_in)


async def save_authorized_account(
    session: AsyncSession,
    *,
    user_id: int,
    client_id: str,
    scope: str,
    token_payload: dict[str, Any],
) -> HikarinagiAccount:
    now = _now()
    active = await session.execute(
        select(HikarinagiAccount).where(HikarinagiAccount.revoked_at.is_(None))
    )
    for account in active.scalars():
        account.revoked_at = now
        account.updated_at = now
        session.add(account)

    claims = _decode_id_token(str(token_payload.get("id_token") or ""))
    account = HikarinagiAccount(
        user_id=user_id,
        client_id=client_id,
        subject=str(claims.get("sub") or "") or None,
        display_name=(
            str(
                claims.get("name")
                or claims.get("nickname")
                or claims.get("preferred_username")
                or ""
            )
            or None
        ),
        avatar_url=str(claims.get("picture") or claims.get("avatar_url") or "") or None,
        scope=str(token_payload.get("scope") or scope or ""),
        token_type=str(token_payload.get("token_type") or "Bearer"),
        access_token=encrypt_secret(str(token_payload.get("access_token") or "")),
        refresh_token=encrypt_secret(str(token_payload.get("refresh_token") or "")),
        expires_at=_expires_at(token_payload),
        created_at=now,
        updated_at=now,
    )
    session.add(account)
    await session.commit()
    await session.refresh(account)
    return account


async def get_active_account(session: AsyncSession) -> HikarinagiAccount | None:
    return (
        await session.execute(
            select(HikarinagiAccount)
            .where(HikarinagiAccount.revoked_at.is_(None))
            .order_by(HikarinagiAccount.updated_at.desc(), HikarinagiAccount.id.desc())
        )
    ).scalars().first()


async def revoke_active_accounts(session: AsyncSession) -> int:
    now = _now()
    result = await session.execute(
        select(HikarinagiAccount).where(HikarinagiAccount.revoked_at.is_(None))
    )
    count = 0
    for account in result.scalars():
        account.revoked_at = now
        account.updated_at = now
        session.add(account)
        count += 1
    await session.commit()
    return count


def account_status_payload(account: HikarinagiAccount | None) -> dict[str, Any]:
    config = load_config()
    payload: dict[str, Any] = {
        "bound": account is not None,
        "client_id_configured": bool(config.scrapers.hikarinagi_client_id.strip()),
        "redirect_uri": configured_redirect_uri(),
        "scope": configured_scope(),
    }
    if account is None:
        return payload
    payload.update(
        {
            "bound_by_user_id": account.user_id,
            "subject": account.subject or "",
            "display_name": account.display_name or "",
            "avatar_url": account.avatar_url or "",
            "token_type": account.token_type or "Bearer",
            "account_scope": account.scope or "",
            "expires_at": account.expires_at.isoformat() if account.expires_at else "",
            "updated_at": account.updated_at.isoformat() if account.updated_at else "",
        }
    )
    return payload


async def _refresh_account_token(
    session: AsyncSession,
    account: HikarinagiAccount,
    client: httpx.AsyncClient,
) -> str:
    refresh_token = decrypt_secret(account.refresh_token)
    if not refresh_token:
        raise RuntimeError("Hikarinagi 授权缺少 refresh_token，请重新绑定")
    resp = await client.post(
        HIKARINAGI_TOKEN_URL,
        data={
            "grant_type": "refresh_token",
            "client_id": account.client_id,
            "refresh_token": refresh_token,
        },
        headers={
            "Accept": "application/json",
            "Content-Type": "application/x-www-form-urlencoded",
        },
    )
    try:
        resp.raise_for_status()
    except httpx.HTTPStatusError as exc:
        if exc.response.status_code in {400, 401, 403}:
            account.revoked_at = _now()
            account.updated_at = _now()
            session.add(account)
            await session.commit()
            raise RuntimeError("Hikarinagi 授权已失效，请重新绑定") from exc
        raise
    payload = resp.json()
    token = str(payload.get("access_token") or "")
    if not token:
        raise RuntimeError("Hikarinagi Token 响应为空")
    account.access_token = encrypt_secret(token)
    if payload.get("refresh_token"):
        account.refresh_token = encrypt_secret(str(payload["refresh_token"]))
    account.scope = str(payload.get("scope") or account.scope or "")
    account.token_type = str(
        payload.get("token_type") or account.token_type or "Bearer"
    )
    account.expires_at = _expires_at(payload)
    account.updated_at = _now()
    session.add(account)
    await session.commit()
    return token


async def get_default_access_token(client: httpx.AsyncClient) -> str:
    import database

    if database._session_factory is None:
        raise RuntimeError("数据库未初始化，无法读取 Hikarinagi 授权")
    async with database._session_factory() as session:
        account = await get_active_account(session)
        if account is None:
            raise RuntimeError("Hikarinagi 账号未绑定，请先在设置中完成授权")
        access_token = decrypt_secret(account.access_token)
        if not account.expires_at:
            return access_token
        if account.expires_at > _now() + timedelta(minutes=2):
            return access_token
        return await _refresh_account_token(session, account, client)
