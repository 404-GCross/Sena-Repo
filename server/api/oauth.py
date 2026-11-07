"""OAuth login and account binding for supported providers (public clients + PKCE)."""

from __future__ import annotations

import base64
import hashlib
import logging
import secrets
import threading
import time
from dataclasses import dataclass
from urllib.parse import urlencode, urlparse

import httpx
import jwt
from fastapi import APIRouter, Depends, Header, HTTPException, Request
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from api.auth import _issue_session_token, get_current_user
from config import load_config
from database import get_session
from models.user import User, UserOAuthBinding
from services.oauth_providers import OAuthProvider, provider, providers
from services.oauth_tokens import save_binding_tokens
from services.oidc import OIDCKeySetError, verify_id_token

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/auth/oauth", tags=["oauth"])

LEGACY_PROVIDER = "nextmoe"
FLOW_TTL_SECONDS = 600
_MAX_FLOWS = 200
LOOPBACK_HOSTS = {"127.0.0.1", "::1"}

_ATTEMPT_WINDOW_SECONDS = 600
_MAX_ATTEMPTS_PER_WINDOW = 120
_attempts: dict[str, list[float]] = {}
_attempts_lock = threading.Lock()


def _client_host(request: Request) -> str:
    return request.client.host if request.client else "unknown"


def _check_rate_limit(request: Request, action: str) -> None:
    key = f"{action}:{_client_host(request)}"
    now = time.monotonic()
    with _attempts_lock:
        recent = [
            stamp
            for stamp in _attempts.get(key, [])
            if now - stamp < _ATTEMPT_WINDOW_SECONDS
        ]
        if len(recent) >= _MAX_ATTEMPTS_PER_WINDOW:
            _attempts[key] = recent
            retry_after = max(
                1, int(_ATTEMPT_WINDOW_SECONDS - (now - recent[0]))
            )
            raise HTTPException(
                status_code=429,
                detail="授权尝试过于频繁，请稍后再试",
                headers={"Retry-After": str(retry_after)},
            )
        recent.append(now)
        _attempts[key] = recent
        if len(_attempts) > 2000:
            stale = [
                item
                for item, stamps in _attempts.items()
                if not stamps or now - stamps[-1] >= _ATTEMPT_WINDOW_SECONDS
            ]
            for item in stale:
                _attempts.pop(item, None)


@dataclass
class OAuthFlow:
    request_id: str
    provider: str
    purpose: str
    state: str
    verifier: str
    redirect_uri: str
    created_at: float
    user_id: int | None = None
    completed: bool = False
    in_progress: bool = False
    subject: str = ""
    name: str = ""
    oauth_id: int | None = None
    tokens: dict | None = None
    nonce: str = ""


_flows: dict[str, OAuthFlow] = {}


def _prune_flows() -> None:
    now = time.monotonic()
    stale = [
        key
        for key, flow in _flows.items()
        if now - flow.created_at > FLOW_TTL_SECONDS
    ]
    for key in stale:
        _flows.pop(key, None)
    if len(_flows) > _MAX_FLOWS:
        oldest = sorted(
            _flows.items(), key=lambda item: item[1].created_at
        )[: len(_flows) - _MAX_FLOWS]
        for key, _ in oldest:
            _flows.pop(key, None)


def consume_setup_binding(request_id: str) -> dict | None:
    """Pop a completed setup OAuth flow and return its binding payload."""
    if not request_id:
        return None
    _prune_flows()
    flow = _flows.get(request_id)
    if flow is None or flow.purpose != "setup" or not flow.completed:
        return None
    _flows.pop(request_id, None)
    return {
        "provider": flow.provider,
        "subject": flow.subject,
        "name": flow.name,
        "user_id": flow.oauth_id,
        "tokens": dict(flow.tokens or {}),
    }


def _is_enabled(spec: OAuthProvider) -> bool:
    return bool(spec.enabled and spec.client_id.strip() and spec.issuer.strip())


def _get_provider(provider_key: str) -> OAuthProvider:
    spec = provider(provider_key)
    if spec is None:
        raise HTTPException(status_code=404, detail="未知的登录提供方")
    return spec


def _http_client_kwargs() -> dict:
    kwargs: dict = {"timeout": 20.0}
    proxy = load_config().proxy
    if proxy:
        kwargs["proxy"] = proxy
    return kwargs


def _validate_redirect(
    spec: OAuthProvider, uri: str, redirect_port: int | None = None
) -> str:
    value = (uri or "").strip()
    if spec.redirect_uri:
        if value and value != spec.redirect_uri:
            raise HTTPException(
                status_code=400,
                detail=f"回调地址必须为 {spec.redirect_uri}",
            )
        return spec.redirect_uri
    if value:
        parsed = urlparse(value)
        if (
            parsed.scheme != "http"
            or parsed.hostname not in LOOPBACK_HOSTS
            or parsed.path != "/callback"
        ):
            raise HTTPException(
                status_code=400, detail="回调地址必须是本机环回地址"
            )
        return value
    if redirect_port is not None:
        if redirect_port < 1 or redirect_port > 65535:
            raise HTTPException(status_code=400, detail="回调端口无效")
        return f"http://127.0.0.1:{redirect_port}/callback"
    raise HTTPException(status_code=400, detail="缺少回调地址")


def _pkce_pair() -> tuple[str, str]:
    verifier = secrets.token_urlsafe(64)
    digest = hashlib.sha256(verifier.encode("utf-8")).digest()
    challenge = base64.urlsafe_b64encode(digest).rstrip(b"=").decode("ascii")
    return verifier, challenge


def _authorize_url(
    spec: OAuthProvider,
    redirect_uri: str,
    state: str,
    challenge: str,
    nonce: str = "",
) -> str:
    params = {
        "client_id": spec.client_id.strip(),
        "redirect_uri": redirect_uri,
        "response_type": "code",
        "scope": spec.scopes.strip() or "openid profile",
        "state": state,
        "code_challenge": challenge,
        "code_challenge_method": "S256",
    }
    if spec.prompt:
        params["prompt"] = spec.prompt
    if nonce:
        params["nonce"] = nonce
    return f"{spec.authorize_url}?{urlencode(params)}"


async def _has_admin(session: AsyncSession) -> bool:
    result = await session.execute(select(User.id).where(User.role == "admin"))
    return result.scalars().first() is not None


async def _exchange_code(
    spec: OAuthProvider,
    code: str,
    flow: OAuthFlow,
) -> dict:
    payload = {
        "grant_type": "authorization_code",
        "code": code,
        "redirect_uri": flow.redirect_uri,
        "client_id": spec.client_id.strip(),
        "code_verifier": flow.verifier,
    }
    try:
        async with httpx.AsyncClient(**_http_client_kwargs()) as client:
            resp = await client.post(
                spec.token_url,
                data=payload,
                headers={
                    "Accept": "application/json",
                    "Content-Type": "application/x-www-form-urlencoded",
                },
            )
    except httpx.HTTPError:
        logger.warning(
            "OAuth token exchange failed: provider=%s network error", spec.key
        )
        raise HTTPException(
            status_code=502, detail=f"无法连接 {spec.label}，请稍后重试"
        )
    if resp.status_code != 200:
        logger.warning(
            "OAuth token exchange rejected: provider=%s status=%s",
            spec.key,
            resp.status_code,
        )
        raise HTTPException(
            status_code=400, detail=f"{spec.label} 授权失败，请重试"
        )
    try:
        data = resp.json()
    except ValueError:
        raise HTTPException(
            status_code=502, detail=f"{spec.label} 返回了无效的响应"
        )
    if not isinstance(data, dict) or not data.get("access_token"):
        logger.warning(
            "OAuth token exchange returned no access_token: provider=%s", spec.key
        )
        raise HTTPException(
            status_code=400, detail=f"{spec.label} 授权失败，请重试"
        )
    return data


def _token_payload(spec: OAuthProvider, tokens: dict) -> dict:
    """NextMoe tokens handed to the client for user-scoped scraping."""
    if spec.key != LEGACY_PROVIDER:
        return {}
    try:
        expires_in = int(tokens.get("expires_in") or 0)
    except (TypeError, ValueError):
        expires_in = 0
    return {
        "nextmoe_access_token": str(tokens.get("access_token") or ""),
        "nextmoe_refresh_token": str(tokens.get("refresh_token") or ""),
        "nextmoe_expires_in": expires_in,
    }


async def _fetch_userinfo(spec: OAuthProvider, access_token: str) -> dict:
    try:
        async with httpx.AsyncClient(**_http_client_kwargs()) as client:
            resp = await client.get(
                spec.userinfo_url,
                headers={"Authorization": f"Bearer {access_token}"},
            )
    except httpx.HTTPError:
        logger.warning(
            "OAuth userinfo request failed: provider=%s network error", spec.key
        )
        raise HTTPException(
            status_code=502, detail=f"无法连接 {spec.label}，请稍后重试"
        )
    if resp.status_code == 403:
        raise HTTPException(
            status_code=403, detail=f"该 {spec.label} 账号已被封禁"
        )
    if resp.status_code != 200:
        logger.warning(
            "OAuth userinfo rejected: provider=%s status=%s",
            spec.key,
            resp.status_code,
        )
        raise HTTPException(
            status_code=400, detail=f"{spec.label} 授权失败，请重试"
        )
    try:
        data = resp.json()
    except ValueError:
        raise HTTPException(
            status_code=502, detail=f"{spec.label} 返回了无效的响应"
        )
    if not isinstance(data, dict) or not data.get("sub"):
        logger.warning("OAuth userinfo missing sub: provider=%s", spec.key)
        raise HTTPException(
            status_code=400, detail=f"{spec.label} 授权失败，请重试"
        )
    return data


async def _fetch_identity(
    spec: OAuthProvider, tokens: dict, flow: OAuthFlow
) -> dict:
    if spec.key != "hikarinagi":
        return await _fetch_userinfo(spec, tokens["access_token"])
    # Hikarinagi catalog tokens cannot call userinfo; identity is in id_token.
    try:
        claims = await verify_id_token(
            spec, tokens, flow.nonce, http_client_kwargs=_http_client_kwargs()
        )
    except OIDCKeySetError:
        logger.warning("OAuth signing key lookup failed: provider=%s", spec.key)
        raise HTTPException(
            status_code=502, detail=f"无法获取 {spec.label} 身份验证公钥，请稍后重试"
        ) from None
    except (jwt.PyJWTError, ValueError, TypeError) as exc:
        logger.warning(
            "OAuth ID token rejected: provider=%s reason=%s",
            spec.key, type(exc).__name__,
        )
        raise HTTPException(
            status_code=400, detail=f"{spec.label} 身份令牌校验失败，请重新授权"
        ) from None

    try:
        async with httpx.AsyncClient(**_http_client_kwargs()) as client:
            response = await client.get(
                "https://api.hikarinagi.org/v3/user/me",
                headers={
                    "Authorization": f"Bearer {tokens['access_token']}",
                    "Accept": "application/json",
                },
            )
            if response.status_code in (401, 403):
                raise HTTPException(
                    status_code=400,
                    detail="Hikarinagi 公开资料授权不足，请启用 user:read 并重新授权",
                )
            response.raise_for_status()
            profile = response.json()
    except (httpx.HTTPError, ValueError):
        logger.warning("OAuth public profile lookup failed: provider=%s", spec.key)
        raise HTTPException(
            status_code=502, detail="无法读取 Hikarinagi 公开资料，请稍后重新授权"
        ) from None
    user_id = profile.get("id") if isinstance(profile, dict) else None
    if type(user_id) is not int or not 0 < user_id <= 9223372036854775807:
        raise HTTPException(status_code=502, detail="Hikarinagi 返回了无效的用户 ID")
    return {**claims, "id": user_id}


def _profile_name(profile: dict) -> str:
    for key in ("name", "nickname", "preferred_username"):
        value = str(profile.get(key) or "").strip()
        if value:
            return value[:128]
    return ""


def _parse_oauth_id(value: object) -> int | None:
    try:
        parsed = int(value)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return None
    return parsed if parsed > 0 else None


def _profile_oauth_id(spec: OAuthProvider, profile: dict) -> int | None:
    if not spec.numeric_user_id:
        return None
    return _parse_oauth_id(profile.get("id"))


async def _binding_by_subject(
    session: AsyncSession, provider_key: str, subject: str
) -> UserOAuthBinding | None:
    return (
        await session.execute(
            select(UserOAuthBinding).where(
                UserOAuthBinding.provider == provider_key,
                UserOAuthBinding.subject == subject,
            )
        )
    ).scalar_one_or_none()


async def _binding_for_user(
    session: AsyncSession, user_id: int, provider_key: str
) -> UserOAuthBinding | None:
    return (
        await session.execute(
            select(UserOAuthBinding).where(
                UserOAuthBinding.user_id == user_id,
                UserOAuthBinding.provider == provider_key,
            )
        )
    ).scalar_one_or_none()


async def _sync_legacy_nextmoe(session: AsyncSession, user: User) -> None:
    """Keep the legacy users.oauth_* columns in sync for NextMoe only."""
    binding = await _binding_for_user(session, user.id, LEGACY_PROVIDER)
    if binding is not None:
        user.oauth_provider = LEGACY_PROVIDER
        user.oauth_subject = binding.subject
        user.oauth_name = binding.name
        user.oauth_user_id = binding.oauth_user_id
    elif user.oauth_provider in (None, LEGACY_PROVIDER):
        user.oauth_provider = None
        user.oauth_subject = None
        user.oauth_name = None
        user.oauth_user_id = None


async def _upsert_binding(
    session: AsyncSession,
    user: User,
    spec: OAuthProvider,
    profile: dict,
    tokens: dict,
) -> UserOAuthBinding:
    subject = str(profile["sub"])
    other = await _binding_by_subject(session, spec.key, subject)
    if other is not None and other.user_id != user.id:
        raise HTTPException(
            status_code=409, detail=f"该 {spec.label} 账号已绑定其他用户"
        )
    binding = await _binding_for_user(session, user.id, spec.key)
    oauth_id = _profile_oauth_id(spec, profile)
    if (
        binding is not None
        and binding.oauth_user_id is not None
        and binding.oauth_user_id != oauth_id
    ):
        raise HTTPException(status_code=409, detail="授权账号与预设的第三方用户 ID 不一致")
    if oauth_id is not None:
        taken = (await session.execute(select(UserOAuthBinding).where(
            UserOAuthBinding.provider == spec.key,
            UserOAuthBinding.oauth_user_id == oauth_id,
            UserOAuthBinding.user_id != user.id,
        ))).scalar_one_or_none()
        if taken is not None:
            raise HTTPException(status_code=409, detail="该第三方用户 ID 已分配给其他用户")
    if binding is None:
        binding = UserOAuthBinding(user_id=user.id, provider=spec.key)
        session.add(binding)
    elif binding.subject and binding.subject != subject:
        raise HTTPException(
            status_code=409,
            detail=f"当前账号已绑定其他 {spec.label} 账号，请先解除绑定",
        )
    binding.provider = spec.key
    binding.subject = subject
    binding.name = _profile_name(profile)
    binding.oauth_user_id = _profile_oauth_id(spec, profile)
    save_binding_tokens(binding, tokens, provider_key=spec.key)
    try:
        await session.flush()
    except IntegrityError:
        await session.rollback()
        raise HTTPException(status_code=409, detail="第三方账号绑定冲突，请重新授权") from None
    if spec.key == LEGACY_PROVIDER:
        await _sync_legacy_nextmoe(session, user)
    return binding


async def _find_login_user(
    session: AsyncSession,
    spec: OAuthProvider,
    profile: dict,
) -> tuple[User | None, UserOAuthBinding | None]:
    subject = str(profile["sub"])
    binding = await _binding_by_subject(session, spec.key, subject)
    oauth_id = _profile_oauth_id(spec, profile)
    if binding is not None and oauth_id is not None:
        if binding.oauth_user_id is not None and binding.oauth_user_id != oauth_id:
            raise HTTPException(status_code=409, detail="第三方账号身份与用户 ID 不一致")
        taken = (await session.execute(select(UserOAuthBinding).where(
            UserOAuthBinding.provider == spec.key,
            UserOAuthBinding.oauth_user_id == oauth_id,
            UserOAuthBinding.user_id != binding.user_id,
        ))).scalar_one_or_none()
        if taken is not None:
            raise HTTPException(status_code=409, detail="第三方账号身份与预绑定用户冲突")
    if binding is not None:
        user = (
            await session.execute(select(User).where(User.id == binding.user_id))
        ).scalar_one_or_none()
        if user is not None:
            return user, binding

    if spec.key == LEGACY_PROVIDER:
        legacy = (
            await session.execute(
                select(User).where(User.oauth_subject == subject)
            )
        ).scalar_one_or_none()
        if legacy is not None:
            return legacy, None

    oauth_id = _profile_oauth_id(spec, profile)
    if oauth_id is None:
        return None, None

    binding = (
        await session.execute(
            select(UserOAuthBinding).where(
                UserOAuthBinding.provider == spec.key,
                UserOAuthBinding.oauth_user_id == oauth_id,
                UserOAuthBinding.subject.is_(None),
            )
        )
    ).scalar_one_or_none()
    if binding is not None:
        user = (
            await session.execute(select(User).where(User.id == binding.user_id))
        ).scalar_one_or_none()
        if user is not None:
            return user, binding

    if spec.key == LEGACY_PROVIDER:
        legacy = (
            await session.execute(
                select(User).where(
                    User.oauth_provider == spec.key,
                    User.oauth_user_id == oauth_id,
                    User.oauth_subject.is_(None),
                )
            )
        ).scalar_one_or_none()
        if legacy is not None:
            return legacy, None
    return None, None


def _provider_meta(spec: OAuthProvider) -> dict:
    return {
        "enabled": _is_enabled(spec),
        "name": spec.label,
        "issuer": spec.issuer,
        "client_id": spec.client_id.strip(),
        "token_url": spec.token_url,
        "fixed_redirect_uri": spec.redirect_uri,
    }


def _binding_payload(binding: UserOAuthBinding | None) -> dict:
    if binding is None:
        return {
            "bound": False,
            "provider": "",
            "subject": "",
            "name": "",
            "user_id": None,
            "has_tokens": False,
        }
    return {
        "bound": bool(binding.subject),
        "provider": binding.provider or "",
        "subject": binding.subject or "",
        "name": binding.name or "",
        "user_id": binding.oauth_user_id,
        "has_tokens": bool(binding.access_token),
    }


class StartRequest(BaseModel):
    purpose: str = "login"
    redirect_uri: str = ""
    redirect_port: int | None = None


class CompleteRequest(BaseModel):
    request_id: str
    code: str
    state: str


@router.get("/providers")
async def oauth_providers():
    """Public login provider metadata."""
    return {
        spec.key: _provider_meta(spec) for spec in providers().values()
    }


async def _start_flow(
    provider_key: str,
    body: StartRequest,
    request: Request,
    authorization: str | None,
    session: AsyncSession,
):
    spec = _get_provider(provider_key)
    if not _is_enabled(spec):
        raise HTTPException(
            status_code=400, detail=f"服务器未启用 {spec.label} 登录"
        )
    _check_rate_limit(request, "start")
    purpose = body.purpose.strip().lower()
    if purpose not in {"login", "bind", "setup"}:
        raise HTTPException(status_code=400, detail="无效的授权用途")

    user: User | None = None
    if authorization:
        try:
            user = await get_current_user(request, authorization, session)
        except HTTPException:
            user = None
    if purpose == "bind" and user is None:
        raise HTTPException(status_code=401, detail="未登录")
    if purpose == "setup" and await _has_admin(session):
        raise HTTPException(status_code=400, detail="服务器已完成初始化")
    if purpose == "login" and not await _has_admin(session):
        raise HTTPException(status_code=400, detail="服务器尚未初始化")

    redirect_uri = _validate_redirect(
        spec, body.redirect_uri, body.redirect_port
    )
    verifier, challenge = _pkce_pair()
    state = secrets.token_urlsafe(24)
    nonce = secrets.token_urlsafe(32) if spec.key == "hikarinagi" else ""
    request_id = secrets.token_urlsafe(24)
    logger.info(
        "OAuth start: provider=%s purpose=%s request_id=%s client=%s",
        spec.key,
        purpose,
        request_id,
        request.client.host if request.client else "-",
    )
    _prune_flows()
    _flows[request_id] = OAuthFlow(
        request_id=request_id,
        provider=spec.key,
        purpose=purpose,
        state=state,
        verifier=verifier,
        redirect_uri=redirect_uri,
        created_at=time.monotonic(),
        nonce=nonce,
        user_id=user.id if purpose == "bind" and user else None,
    )
    return {
        "request_id": request_id,
        "state": state,
        "authorize_url": _authorize_url(spec, redirect_uri, state, challenge, nonce),
        "expires_in": FLOW_TTL_SECONDS,
    }


@router.post("/{provider_key}/start")
async def oauth_start_provider(
    provider_key: str,
    body: StartRequest,
    request: Request,
    authorization: str | None = Header(default=None),
    session: AsyncSession = Depends(get_session),
):
    return await _start_flow(
        provider_key, body, request, authorization, session
    )


@router.post("/start")
async def oauth_start(
    body: StartRequest,
    request: Request,
    authorization: str | None = Header(default=None),
    session: AsyncSession = Depends(get_session),
):
    """Legacy route kept for clients that predate multi-provider support."""
    return await _start_flow(
        LEGACY_PROVIDER, body, request, authorization, session
    )


async def _complete_flow(
    provider_key: str,
    body: CompleteRequest,
    request: Request,
    authorization: str | None,
    session: AsyncSession,
):
    spec = _get_provider(provider_key)
    if not _is_enabled(spec):
        raise HTTPException(
            status_code=400, detail=f"服务器未启用 {spec.label} 登录"
        )
    _check_rate_limit(request, "complete")
    _prune_flows()
    flow = _flows.get(body.request_id)
    if flow is None or flow.provider != spec.key:
        raise HTTPException(status_code=400, detail="授权请求已失效，请重试")
    if not body.state or not secrets.compare_digest(body.state, flow.state):
        _flows.pop(body.request_id, None)
        raise HTTPException(status_code=400, detail="授权校验失败，请重试")
    if flow.in_progress or (flow.purpose == "setup" and flow.completed):
        raise HTTPException(status_code=400, detail="该授权正在处理或已完成")
    flow.in_progress = True
    if flow.purpose != "setup":
        _flows.pop(body.request_id, None)

    code = (body.code or "").strip()
    if not code:
        if flow.purpose == "setup":
            flow.in_progress = False
        raise HTTPException(status_code=400, detail="缺少授权码")
    try:
        tokens = await _exchange_code(spec, code, flow)
        profile = await _fetch_identity(spec, tokens, flow)
    except Exception:
        _flows.pop(body.request_id, None)
        raise
    subject = str(profile["sub"])
    name = _profile_name(profile)
    oauth_id = _profile_oauth_id(spec, profile)

    if flow.purpose == "setup":
        flow.completed = True
        flow.in_progress = False
        flow.subject = subject
        flow.name = name
        flow.oauth_id = oauth_id
        flow.tokens = tokens
        return {
            "bound": True,
            "provider": spec.key,
            "name": name,
            "user_id": oauth_id,
        }

    if flow.purpose == "bind":
        user = None
        if authorization:
            try:
                user = await get_current_user(request, authorization, session)
            except HTTPException:
                user = None
        if user is None or flow.user_id != user.id:
            raise HTTPException(status_code=401, detail="登录状态已失效，请重试")
        binding = await _upsert_binding(session, user, spec, profile, tokens)
        try:
            await session.commit()
        except IntegrityError as exc:
            await session.rollback()
            raise HTTPException(
                status_code=409,
                detail=f"该 {spec.label} 账号已绑定其他用户",
            ) from exc
        logger.info(
            "OAuth account bound: user_id=%s provider=%s", user.id, spec.key
        )
        return {
            "bound": True,
            "provider": spec.key,
            "name": binding.name or "",
            "user_id": binding.oauth_user_id,
            **_token_payload(spec, tokens),
        }

    user, binding = await _find_login_user(session, spec, profile)
    if user is None:
        hint = f"（ID {oauth_id}）" if oauth_id is not None else ""
        logger.info(
            "OAuth login rejected: provider=%s account not provisioned", spec.key
        )
        raise HTTPException(
            status_code=403,
            detail=f"该 {spec.label} 账号{hint}尚未被服务器添加，请联系管理员",
        )

    if binding is not None:
        binding.subject = subject
        binding.name = name
        binding.oauth_user_id = oauth_id if oauth_id is not None else binding.oauth_user_id
        save_binding_tokens(binding, tokens, provider_key=spec.key)
    else:
        binding = await _upsert_binding(session, user, spec, profile, tokens)
    if spec.key == LEGACY_PROVIDER:
        await _sync_legacy_nextmoe(session, user)

    if user.status != "active":
        logger.info(
            "OAuth login blocked: user_id=%s status=%s", user.id, user.status
        )
        await session.rollback()
        raise HTTPException(status_code=403, detail="账户已被停用")

    token = await _issue_session_token(user, session, request)
    try:
        await session.commit()
    except IntegrityError as exc:
        await session.rollback()
        raise HTTPException(
            status_code=409, detail="账号绑定状态发生变化，请重试"
        ) from exc
    logger.info(
        "OAuth login succeeded: user_id=%s provider=%s role=%s",
        user.id,
        spec.key,
        user.role,
    )
    return {
        "token": token,
        "id": user.id,
        "is_admin": user.role == "admin",
        "role": user.role,
        "username": user.username,
        **_token_payload(spec, tokens),
    }


@router.post("/{provider_key}/complete")
async def oauth_complete_provider(
    provider_key: str,
    body: CompleteRequest,
    request: Request,
    authorization: str | None = Header(default=None),
    session: AsyncSession = Depends(get_session),
):
    return await _complete_flow(
        provider_key, body, request, authorization, session
    )


@router.post("/complete")
async def oauth_complete(
    body: CompleteRequest,
    request: Request,
    authorization: str | None = Header(default=None),
    session: AsyncSession = Depends(get_session),
):
    """Legacy route kept for clients that predate multi-provider support."""
    return await _complete_flow(
        LEGACY_PROVIDER, body, request, authorization, session
    )


async def _bindings_payload(current: User, session: AsyncSession) -> dict:
    rows = list(
        (
            await session.execute(
                select(UserOAuthBinding).where(
                    UserOAuthBinding.user_id == current.id
                )
            )
        ).scalars()
    )
    by_provider = {row.provider: row for row in rows}
    bound_providers = {
        key for key, row in by_provider.items() if row.subject
    }
    payload = {}
    for spec in providers().values():
        entry = _binding_payload(by_provider.get(spec.key))
        entry["enabled"] = _is_enabled(spec)
        entry["label"] = spec.label
        entry["can_unbind"] = bool(
            current.password_set or (bound_providers - {spec.key})
        )
        payload[spec.key] = entry
    return {
        "bindings": payload,
        "password_set": bool(current.password_set),
        "can_unbind": bool(
            current.password_set or len(bound_providers) > 1
        ),
    }


@router.get("/bindings")
async def oauth_bindings(
    current: User = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
):
    return await _bindings_payload(current, session)


@router.get("/binding")
async def oauth_binding(
    current: User = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
):
    data = await _bindings_payload(current, session)
    nextmoe = data["bindings"].get(LEGACY_PROVIDER, _binding_payload(None))
    return {**nextmoe, **data}


@router.delete("/binding/{provider_key}")
async def oauth_unbind_provider(
    provider_key: str,
    current: User = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
):
    spec = _get_provider(provider_key)
    other_binding = (
        await session.execute(
            select(UserOAuthBinding).where(
                UserOAuthBinding.user_id == current.id,
                UserOAuthBinding.provider != spec.key,
                UserOAuthBinding.subject.isnot(None),
            )
        )
    ).scalar_one_or_none()
    if not current.password_set and other_binding is None:
        raise HTTPException(
            status_code=400,
            detail="当前账号没有本地密码，也没有其他已绑定的第三方账号，请先设置密码后再解除绑定",
        )
    binding = await _binding_for_user(session, current.id, spec.key)
    if binding is None:
        raise HTTPException(
            status_code=400, detail=f"当前账号未绑定 {spec.label}"
        )
    await session.delete(binding)
    await session.flush()
    if spec.key == LEGACY_PROVIDER:
        await _sync_legacy_nextmoe(session, current)
    await session.commit()
    logger.info(
        "OAuth account unbound: user_id=%s provider=%s", current.id, spec.key
    )
    return {"message": f"已解除 {spec.label} 绑定"}


@router.delete("/binding")
async def oauth_unbind(
    current: User = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
):
    """Legacy route kept for clients that predate multi-provider support."""
    return await oauth_unbind_provider(LEGACY_PROVIDER, current, session)
