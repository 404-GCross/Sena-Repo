"""Persist and refresh provider tokens bound to a Sena account."""

from __future__ import annotations

import logging
from datetime import datetime, timedelta
from typing import Awaitable, Callable

import httpx
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from config import load_config
from models.user import UserOAuthBinding
from services.oauth_providers import OAuthProvider, provider
from utils.secrets import decrypt_secret, encrypt_secret

logger = logging.getLogger(__name__)

_REFRESH_SKEW = timedelta(seconds=60)
TokenProvider = Callable[[bool], Awaitable[str | None]]


class OAuthTokenError(RuntimeError):
    """Temporary token problem that can be retried later."""


class OAuthReauthRequired(OAuthTokenError):
    """Stored authorization is no longer usable; the user must authorize again."""


def save_binding_tokens(
    binding: UserOAuthBinding,
    tokens: dict,
    *,
    provider_key: str = "",
) -> None:
    """Store tokens returned by the OP encrypted at rest."""
    access = str(tokens.get("access_token") or "")
    if not access:
        return
    binding.access_token = encrypt_secret(access)
    refresh = str(tokens.get("refresh_token") or "")
    if refresh:
        binding.refresh_token = encrypt_secret(refresh)
    try:
        expires_in = int(tokens.get("expires_in") or 0)
    except (TypeError, ValueError):
        expires_in = 0
    binding.expires_at = (
        datetime.utcnow() + timedelta(seconds=expires_in)
        if expires_in > 0
        else None
    )
    scope = str(tokens.get("scope") or "").strip()
    if scope:
        binding.scope = scope[:256]
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
    if not isinstance(data, dict) or not data.get("access_token"):
        raise OAuthReauthRequired(
            f"{spec.label} 授权已失效，请重新绑定或登录以授权目录读取"
        )
    return data


async def get_provider_access_token(
    session: AsyncSession,
    user_id: int,
    provider_key: str,
    *,
    force_refresh: bool = False,
) -> str | None:
    """Return a usable user token, or None when this user never bound it.

    Raises OAuthReauthRequired when the binding exists but must be authorized
    again, and OAuthTokenError for temporary failures.
    """
    spec = provider(provider_key)
    if spec is None or not spec.enabled:
        return None
    binding = (
        await session.execute(
            select(UserOAuthBinding).where(
                UserOAuthBinding.user_id == user_id,
                UserOAuthBinding.provider == spec.key,
            )
        )
    ).scalar_one_or_none()
    if binding is None or not binding.subject:
        return None

    access = _decrypt(binding.access_token)
    now = datetime.utcnow()
    if (
        access
        and not force_refresh
        and (binding.expires_at is None or binding.expires_at - _REFRESH_SKEW > now)
    ):
        return access

    refresh = _decrypt(binding.refresh_token)
    if not refresh:
        if access and binding.expires_at is None:
            return access
        raise OAuthReauthRequired(
            f"{spec.label} 授权已失效，请重新绑定或登录以授权目录读取"
        )

    stored_refresh = binding.refresh_token
    try:
        tokens = await _refresh_tokens(spec, refresh)
    except httpx.HTTPError as exc:
        logger.warning(
            "OAuth token refresh network failure: provider=%s", spec.key
        )
        raise OAuthTokenError(
            f"暂时无法刷新 {spec.label} 授权，请稍后重试"
        ) from exc

    # Another request may have refreshed the same binding while we waited.
    try:
        await session.refresh(binding)
    except Exception as exc:
        logger.warning(
            "OAuth binding disappeared during refresh: provider=%s", spec.key
        )
        raise OAuthReauthRequired(
            f"{spec.label} 授权已失效，请重新绑定或登录以授权目录读取"
        ) from exc
    if binding.refresh_token != stored_refresh:
        concurrent_access = _decrypt(binding.access_token)
        if concurrent_access:
            return concurrent_access

    if not tokens.get("refresh_token"):
        tokens["refresh_token"] = refresh
    save_binding_tokens(binding, tokens, provider_key=spec.key)
    await session.commit()
    return str(tokens["access_token"])


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
