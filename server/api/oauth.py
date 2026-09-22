"""NextMoe·未萌 OAuth login and account binding (public client + PKCE)."""

from __future__ import annotations

import base64
import hashlib
import logging
import re
import secrets
import time
from dataclasses import dataclass
from urllib.parse import urlencode, urlparse

import httpx
from fastapi import APIRouter, Depends, Header, HTTPException, Request
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from api.auth import _issue_session_token, get_current_user
from config import load_config
from database import get_session
from models.user import Notification, User, hash_password

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/auth/oauth", tags=["oauth"])

PROVIDER = "nextmoe"
PROVIDER_LABEL = "鲲Galgame"
FLOW_TTL_SECONDS = 600
USERNAME_MAX_LEN = 110
LOOPBACK_HOSTS = {"127.0.0.1", "::1"}


@dataclass
class OAuthFlow:
    request_id: str
    purpose: str
    state: str
    verifier: str
    redirect_uri: str
    created_at: float
    user_id: int | None = None
    completed: bool = False
    subject: str = ""
    name: str = ""
    oauth_id: int | None = None


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


def consume_setup_binding(request_id: str) -> tuple[str, str, int | None] | None:
    """Pop a completed setup OAuth flow and return its (subject, name, user_id)."""
    if not request_id:
        return None
    _prune_flows()
    flow = _flows.get(request_id)
    if flow is None or flow.purpose != "setup" or not flow.completed:
        return None
    _flows.pop(request_id, None)
    return flow.subject, flow.name, flow.oauth_id


def _oauth_config():
    return load_config().oauth


def _is_enabled() -> bool:
    config = _oauth_config()
    return bool(config.enabled and config.client_id.strip() and config.issuer.strip())


def _http_client_kwargs() -> dict:
    kwargs: dict = {"timeout": 20.0}
    proxy = load_config().proxy
    if proxy:
        kwargs["proxy"] = proxy
    return kwargs


def _validate_loopback_redirect(uri: str) -> str:
    parsed = urlparse(uri or "")
    if (
        parsed.scheme != "http"
        or parsed.hostname not in LOOPBACK_HOSTS
        or parsed.path != "/callback"
    ):
        raise HTTPException(status_code=400, detail="回调地址必须是本机环回地址")
    return uri


def _pkce_pair() -> tuple[str, str]:
    verifier = secrets.token_urlsafe(64)
    digest = hashlib.sha256(verifier.encode("utf-8")).digest()
    challenge = base64.urlsafe_b64encode(digest).rstrip(b"=").decode("ascii")
    return verifier, challenge


def _authorize_url(
    redirect_uri: str, state: str, challenge: str
) -> str:
    config = _oauth_config()
    query = urlencode(
        {
            "client_id": config.client_id.strip(),
            "redirect_uri": redirect_uri,
            "response_type": "code",
            "scope": config.scopes.strip() or "openid profile",
            "state": state,
            "code_challenge": challenge,
            "code_challenge_method": "S256",
        }
    )
    return f"{config.issuer.rstrip('/')}/oauth/authorize?{query}"


async def _has_owner(session: AsyncSession) -> bool:
    result = await session.execute(select(User).where(User.role == "owner"))
    return result.scalar_one_or_none() is not None


async def _exchange_code(config, code: str, flow: OAuthFlow) -> dict:
    payload = {
        "grant_type": "authorization_code",
        "code": code,
        "redirect_uri": flow.redirect_uri,
        "client_id": config.client_id.strip(),
        "code_verifier": flow.verifier,
    }
    url = f"{config.issuer.rstrip('/')}/oauth/token"
    try:
        async with httpx.AsyncClient(**_http_client_kwargs()) as client:
            resp = await client.post(url, data=payload)
    except httpx.HTTPError:
        logger.warning("OAuth token exchange failed: network error")
        raise HTTPException(status_code=502, detail="无法连接 鲲Galgame，请稍后重试")
    if resp.status_code != 200:
        logger.warning(
            "OAuth token exchange rejected: status=%s", resp.status_code
        )
        raise HTTPException(status_code=400, detail="鲲Galgame 授权失败，请重试")
    try:
        data = resp.json()
    except ValueError:
        raise HTTPException(status_code=502, detail="鲲Galgame 返回了无效的响应")
    if not data.get("access_token"):
        logger.warning("OAuth token exchange returned no access_token")
        raise HTTPException(status_code=400, detail="鲲Galgame 授权失败，请重试")
    return data


def _token_payload(tokens: dict) -> dict:
    """NextMoe tokens handed to the client for user-scoped scraping."""
    try:
        expires_in = int(tokens.get("expires_in") or 0)
    except (TypeError, ValueError):
        expires_in = 0
    return {
        "nextmoe_access_token": str(tokens.get("access_token") or ""),
        "nextmoe_refresh_token": str(tokens.get("refresh_token") or ""),
        "nextmoe_expires_in": expires_in,
    }


async def _fetch_userinfo(config, access_token: str) -> dict:
    url = f"{config.issuer.rstrip('/')}/oauth/userinfo"
    try:
        async with httpx.AsyncClient(**_http_client_kwargs()) as client:
            resp = await client.get(
                url, headers={"Authorization": f"Bearer {access_token}"}
            )
    except httpx.HTTPError:
        logger.warning("OAuth userinfo request failed: network error")
        raise HTTPException(status_code=502, detail="无法连接 鲲Galgame，请稍后重试")
    if resp.status_code == 403:
        raise HTTPException(status_code=403, detail="该 鲲Galgame账号 已被封禁")
    if resp.status_code != 200:
        logger.warning("OAuth userinfo rejected: status=%s", resp.status_code)
        raise HTTPException(status_code=400, detail="鲲Galgame 授权失败，请重试")
    try:
        data = resp.json()
    except ValueError:
        raise HTTPException(status_code=502, detail="鲲Galgame 返回了无效的响应")
    subject = data.get("sub")
    if not subject:
        logger.warning("OAuth userinfo missing sub")
        raise HTTPException(status_code=400, detail="鲲Galgame 授权失败，请重试")
    return data


def _normalize_username(raw: str) -> str:
    cleaned = re.sub(r"\s+", "_", (raw or "").strip()).casefold()
    return cleaned[:USERNAME_MAX_LEN]


def _parse_oauth_id(value: object) -> int | None:
    try:
        parsed = int(value)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return None
    return parsed if parsed > 0 else None


async def _derive_username(
    session: AsyncSession, name: str, oauth_id: object
) -> str:
    base = _normalize_username(name)
    if len(base) < 2:
        base = ""
    suffix = str(oauth_id).strip() if oauth_id is not None else ""
    candidates: list[str] = []
    if base:
        candidates.append(base)
        if suffix:
            candidates.append(f"{base}_{suffix}")
    if suffix:
        candidates.append(f"nextmoe_{suffix}")
    candidates.append(f"nextmoe_{secrets.token_hex(4)}")
    for candidate in candidates:
        candidate = _normalize_username(candidate)[:128]
        if len(candidate) < 2:
            continue
        existing = await session.execute(
            select(User).where(User.username == candidate)
        )
        if existing.scalar_one_or_none() is None:
            return candidate
    return f"nextmoe_{secrets.token_hex(8)}"


async def _notify_admins_new_user(
    session: AsyncSession, user: User, source: str
) -> None:
    admins = await session.execute(
        select(User).where(User.role.in_(("owner", "admin")))
    )
    for admin in admins.scalars():
        session.add(
            Notification(
                type="approval_request",
                title=f"新用户注册: {user.username}",
                body=f"用户 {user.username} 通过{source}申请账户，等待审批",
                target_user_id=user.id,
            )
        )


class StartRequest(BaseModel):
    purpose: str = "login"
    redirect_uri: str = ""


class CompleteRequest(BaseModel):
    request_id: str
    code: str
    state: str


@router.get("/providers")
async def oauth_providers():
    """Public login provider metadata."""
    config = _oauth_config()
    return {
        PROVIDER: {
            "enabled": _is_enabled(),
            "name": PROVIDER_LABEL,
            "issuer": config.issuer,
            "client_id": config.client_id.strip(),
        }
    }


@router.post("/start")
async def oauth_start(
    body: StartRequest,
    authorization: str | None = Header(default=None),
    session: AsyncSession = Depends(get_session),
):
    if not _is_enabled():
        raise HTTPException(status_code=400, detail="服务器未启用 鲲Galgame 登录")
    purpose = body.purpose.strip().lower()
    if purpose not in {"login", "bind", "setup"}:
        raise HTTPException(status_code=400, detail="无效的授权用途")

    user: User | None = None
    if authorization:
        try:
            user = await get_current_user(authorization, session)
        except HTTPException:
            user = None
    if purpose == "bind" and user is None:
        raise HTTPException(status_code=401, detail="未登录")
    if purpose == "setup" and await _has_owner(session):
        raise HTTPException(status_code=400, detail="服务器已完成初始化")
    if purpose == "login" and not await _has_owner(session):
        raise HTTPException(status_code=400, detail="服务器尚未初始化")

    redirect_uri = _validate_loopback_redirect(body.redirect_uri)
    verifier, challenge = _pkce_pair()
    state = secrets.token_urlsafe(24)
    request_id = secrets.token_urlsafe(24)
    _prune_flows()
    _flows[request_id] = OAuthFlow(
        request_id=request_id,
        purpose=purpose,
        state=state,
        verifier=verifier,
        redirect_uri=redirect_uri,
        created_at=time.monotonic(),
        user_id=user.id if purpose == "bind" and user else None,
    )
    return {
        "request_id": request_id,
        "state": state,
        "authorize_url": _authorize_url(redirect_uri, state, challenge),
        "expires_in": FLOW_TTL_SECONDS,
    }


@router.post("/complete")
async def oauth_complete(
    body: CompleteRequest,
    request: Request,
    authorization: str | None = Header(default=None),
    session: AsyncSession = Depends(get_session),
):
    if not _is_enabled():
        raise HTTPException(status_code=400, detail="服务器未启用 鲲Galgame 登录")
    _prune_flows()
    flow = _flows.get(body.request_id)
    if flow is None:
        raise HTTPException(status_code=400, detail="授权请求已失效，请重试")
    if not body.state or not secrets.compare_digest(body.state, flow.state):
        _flows.pop(body.request_id, None)
        raise HTTPException(status_code=400, detail="授权校验失败，请重试")
    if flow.purpose == "setup" and flow.completed:
        raise HTTPException(status_code=400, detail="该授权已完成")

    config = _oauth_config()
    code = (body.code or "").strip()
    if not code:
        raise HTTPException(status_code=400, detail="缺少授权码")
    tokens = await _exchange_code(config, code, flow)
    access_token = tokens["access_token"]
    profile = await _fetch_userinfo(config, access_token)
    subject = str(profile["sub"])
    name = str(profile.get("name") or "").strip()

    if flow.purpose == "setup":
        flow.completed = True
        flow.subject = subject
        flow.name = name
        flow.oauth_id = _parse_oauth_id(profile.get("id"))
        return {
            "bound": True,
            "name": name,
            "user_id": flow.oauth_id,
            **_token_payload(tokens),
        }

    if flow.purpose == "bind":
        _flows.pop(body.request_id, None)
        user = None
        if authorization:
            try:
                user = await get_current_user(authorization, session)
            except HTTPException:
                user = None
        if user is None or flow.user_id != user.id:
            raise HTTPException(status_code=401, detail="登录状态已失效，请重试")
        existing = await session.execute(
            select(User).where(User.oauth_subject == subject)
        )
        bound_user = existing.scalar_one_or_none()
        if bound_user is not None and bound_user.id != user.id:
            raise HTTPException(
                status_code=409, detail="该 鲲Galgame账号 已绑定其他用户"
            )
        user.oauth_provider = PROVIDER
        user.oauth_subject = subject
        user.oauth_name = name
        user.oauth_user_id = _parse_oauth_id(profile.get("id"))
        await session.commit()
        logger.info("OAuth account bound: user_id=%s", user.id)
        return {
            "bound": True,
            "name": name,
            "user_id": user.oauth_user_id,
            **_token_payload(tokens),
        }

    # purpose == "login"
    _flows.pop(body.request_id, None)
    result = await session.execute(
        select(User).where(User.oauth_subject == subject)
    )
    user = result.scalar_one_or_none()
    if user is None:
        oauth_id = _parse_oauth_id(profile.get("id"))
        if oauth_id is not None:
            pre_created = await session.execute(
                select(User).where(
                    User.oauth_provider == PROVIDER,
                    User.oauth_user_id == oauth_id,
                    User.oauth_subject.is_(None),
                )
            )
            user = pre_created.scalar_one_or_none()
            if user is not None:
                user.oauth_subject = subject
                user.oauth_name = name
                await session.flush()
                logger.info(
                    "OAuth account auto-bound by user id: user_id=%s", user.id
                )
    if user is None:
        username = await _derive_username(session, name, profile.get("id"))
        password_hash, salt = hash_password(secrets.token_urlsafe(32))
        user = User(
            username=username,
            password_hash=password_hash,
            salt=salt,
            role="user",
            is_admin=False,
            status="pending",
            oauth_provider=PROVIDER,
            oauth_subject=subject,
            oauth_name=name,
            oauth_user_id=_parse_oauth_id(profile.get("id")),
            password_set=False,
        )
        session.add(user)
        try:
            await session.flush()
            await _notify_admins_new_user(session, user, "鲲Galgame")
            await session.commit()
        except Exception:
            await session.rollback()
            raise
        logger.info(
            "OAuth registration submitted: user_id=%s username=%s",
            user.id,
            user.username,
        )
        return {"pending": True, "username": user.username, "created": True}

    if user.status == "pending":
        logger.info("OAuth login blocked pending: user_id=%s", user.id)
        return {"pending": True, "username": user.username}
    if user.status == "rejected":
        logger.info("OAuth login blocked rejected: user_id=%s", user.id)
        return {"rejected": True, "username": user.username}

    token = await _issue_session_token(user, session, request)
    await session.commit()
    logger.info("OAuth login succeeded: user_id=%s role=%s", user.id, user.role)
    return {
        "token": token,
        "id": user.id,
        "is_admin": user.role in ("owner", "admin"),
        "role": user.role,
        "username": user.username,
        **_token_payload(tokens),
    }


@router.get("/binding")
async def oauth_binding(
    current: User = Depends(get_current_user),
):
    return {
        "bound": bool(current.oauth_subject),
        "provider": current.oauth_provider or "",
        "subject": current.oauth_subject or "",
        "name": current.oauth_name or "",
        "user_id": current.oauth_user_id,
        "password_set": bool(current.password_set),
    }


@router.delete("/binding")
async def oauth_unbind(
    current: User = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
):
    if not current.oauth_subject:
        raise HTTPException(status_code=400, detail="当前账号未绑定 鲲Galgame")
    if not current.password_set:
        raise HTTPException(
            status_code=400,
            detail="请先在「修改密码」中设置本地密码，再解除绑定",
        )
    current.oauth_provider = None
    current.oauth_subject = None
    current.oauth_name = None
    current.oauth_user_id = None
    await session.commit()
    logger.info("OAuth account unbound: user_id=%s", current.id)
    return {"message": "已解除绑定"}
