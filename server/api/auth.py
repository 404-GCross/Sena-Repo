"""Auth API - login and user management with admin/user roles."""

from __future__ import annotations
import hashlib
import logging
import secrets
import threading
import time
from math import ceil
from datetime import datetime, timedelta

from fastapi import APIRouter, Depends, File, Header, HTTPException, Request, UploadFile
from pydantic import BaseModel, Field
from sqlalchemy import or_, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.exc import IntegrityError

from config import load_config
from database import get_session
from models.user import User, UserSession, hash_password, verify_password

router = APIRouter(prefix="/api/auth", tags=["auth"])

logger = logging.getLogger(__name__)

_LOGIN_FAILURE_LIMIT = 5
_LOGIN_FAILURE_WINDOW_SECONDS = 15 * 60
_LOGIN_BLOCK_SECONDS = 5 * 60
_LOGIN_FAILURE_MAX_ENTRIES = 10_000
_LOGIN_HOST_FAILURE_LIMIT = 120
_login_failure_lock = threading.Lock()
_login_failures: dict[tuple[str, str], tuple[int, float, float]] = {}


def _login_key(body: "LoginRequest", request: Request) -> tuple[str, str]:
    username = body.username.strip().casefold()[:128]
    client_host = request.client.host if request.client else "unknown"
    return username, client_host[:255]


def _prune_login_failures(now: float) -> None:
    stale = [
        key
        for key, (_, window_started, blocked_until) in _login_failures.items()
        if now - window_started >= _LOGIN_FAILURE_WINDOW_SECONDS
        and blocked_until <= now
    ]
    for key in stale:
        _login_failures.pop(key, None)
    if len(_login_failures) > _LOGIN_FAILURE_MAX_ENTRIES:
        excess = len(_login_failures) - _LOGIN_FAILURE_MAX_ENTRIES
        oldest = sorted(
            _login_failures.items(),
            key=lambda item: max(item[1][1], item[1][2]),
        )[:excess]
        for key, _ in oldest:
            _login_failures.pop(key, None)


def _login_retry_after(key: tuple[str, str]) -> int:
    now = time.monotonic()
    with _login_failure_lock:
        _prune_login_failures(now)
        state = _login_failures.get(key)
        if state is None:
            return 0
        _, window_started, blocked_until = state
        if now - window_started >= _LOGIN_FAILURE_WINDOW_SECONDS:
            _login_failures.pop(key, None)
            return 0
        if blocked_until > now:
            return max(1, ceil(blocked_until - now))
        return 0


def _record_login_failure(
    key: tuple[str, str], *, limit: int = _LOGIN_FAILURE_LIMIT
) -> int:
    now = time.monotonic()
    with _login_failure_lock:
        _prune_login_failures(now)
        failures, window_started, blocked_until = _login_failures.get(
            key, (0, now, 0.0)
        )
        if now - window_started >= _LOGIN_FAILURE_WINDOW_SECONDS:
            failures, window_started, blocked_until = 0, now, 0.0
        failures += 1
        if failures >= limit:
            blocked_until = max(blocked_until, now + _LOGIN_BLOCK_SECONDS)
        _login_failures[key] = (failures, window_started, blocked_until)
        return max(0, ceil(blocked_until - now))


def _clear_login_failures(key: tuple[str, str]) -> None:
    with _login_failure_lock:
        _login_failures.pop(key, None)


def _integrity_conflict_detail(exc: IntegrityError) -> str | None:
    message = str(exc).lower()
    if "users.username" in message:
        return "用户名已存在"
    if "ix_users_oauth_user_id" in message or "users.oauth_user_id" in message:
        return "该 NextMoe 用户 ID 已被使用"
    return None


def _ensure_profile_edit_access(current: User, target: User) -> None:
    if current.id == target.id:
        return
    if current.role == "admin" and target.role == "user":
        return
    raise HTTPException(status_code=403, detail="管理员只能修改自己的资料或普通用户资料")


def _token_expires_at() -> datetime:
    days = max(1, load_config().server.token_expire_days)
    return datetime.utcnow() + timedelta(days=days)


def _token_lifetime() -> timedelta:
    days = max(1, load_config().server.token_expire_days)
    return timedelta(days=days)


def _token_hash(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def _extract_bearer_token(authorization: str | None) -> str:
    if not authorization:
        raise HTTPException(status_code=401, detail="未登录")
    if not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="无效的认证格式")
    token = authorization.removeprefix("Bearer ").strip()
    if not token:
        raise HTTPException(status_code=401, detail="令牌无效或已过期")
    return token


def _device_name(request: Request | None) -> str:
    if request is None:
        return ""
    value = request.headers.get("user-agent", "").strip()
    return value[:256]


async def _issue_session_token(
    user: User,
    session: AsyncSession,
    request: Request | None = None,
) -> str:
    token = secrets.token_urlsafe(32)
    now = datetime.utcnow()
    session.add(
        UserSession(
            user_id=user.id,
            token_hash=_token_hash(token),
            device_name=_device_name(request),
            created_at=now,
            last_seen_at=now,
            expires_at=_token_expires_at(),
        )
    )
    return token


async def _touch_session(auth_session: UserSession, session: AsyncSession) -> None:
    now = datetime.utcnow()
    lifetime = _token_lifetime()
    needs_commit = False
    if (
        auth_session.last_seen_at is None
        or now - auth_session.last_seen_at > timedelta(minutes=5)
    ):
        auth_session.last_seen_at = now
        needs_commit = True
    if auth_session.expires_at - now < lifetime / 2:
        auth_session.expires_at = _token_expires_at()
        needs_commit = True
    if needs_commit:
        await session.commit()


async def _revoke_user_sessions(user_id: int, session: AsyncSession) -> None:
    now = datetime.utcnow()
    result = await session.execute(
        select(UserSession).where(
            UserSession.user_id == user_id,
            UserSession.revoked_at.is_(None),
        )
    )
    for auth_session in result.scalars():
        auth_session.revoked_at = now


# ── Auth dependencies ───────────────────────────────────────────────────────

async def get_current_user(
    authorization: str | None = Header(default=None),
    session: AsyncSession = Depends(get_session),
) -> User:
    token = _extract_bearer_token(authorization)
    now = datetime.utcnow()

    auth_session = (
        await session.execute(
            select(UserSession).where(
                UserSession.token_hash == _token_hash(token),
                UserSession.revoked_at.is_(None),
            )
        )
    ).scalar_one_or_none()
    if auth_session is None:
        raise HTTPException(status_code=401, detail="令牌无效或已过期")
    if auth_session.expires_at <= now:
        auth_session.revoked_at = now
        await session.commit()
        raise HTTPException(status_code=401, detail="令牌无效或已过期")

    user = (
        await session.execute(
            select(User).where(
                User.id == auth_session.user_id,
                User.status == "active",
            )
        )
    ).scalar_one_or_none()
    if user is None:
        auth_session.revoked_at = now
        await session.commit()
        raise HTTPException(status_code=401, detail="令牌无效或已过期")

    await _touch_session(auth_session, session)
    return user


async def require_admin(user: User = Depends(get_current_user)) -> User:
    """Require administrator privileges."""
    if user.role != "admin":
        raise HTTPException(status_code=403, detail="需要管理员权限")
    return user


async def _ensure_not_last_admin(session: AsyncSession, user: User) -> None:
    """Keep at least one active administrator so the server stays manageable."""
    if user.role != "admin":
        return
    remaining = (
        await session.execute(
            select(User.id).where(
                User.role == "admin",
                User.id != user.id,
                User.status == "active",
                or_(
                    User.password_set.is_(True),
                    User.oauth_subject.isnot(None),
                    User.oauth_user_id.isnot(None),
                ),
            )
        )
    ).scalars().first()
    if remaining is None:
        raise HTTPException(status_code=400, detail="必须保留至少一个可用的管理员")


# ── Schemas ─────────────────────────────────────────────────────────────────

class LoginRequest(BaseModel):
    username: str
    password: str


class LoginResponse(BaseModel):
    token: str
    id: int
    is_admin: bool
    role: str
    username: str


class AdminUserUpdate(BaseModel):
    username: str | None = None
    password: str | None = None
    is_admin: bool | None = None   # legacy; ignored if role is set
    role: str | None = None        # admin | user
    nextmoe_user_id: int | None = None
    clear_nextmoe: bool = False


# ── Auth endpoints ───────────────────────────────────────────────────────────

@router.post("/login", response_model=LoginResponse)
async def login(
    body: LoginRequest,
    request: Request,
    session: AsyncSession = Depends(get_session),
):
    login_key = _login_key(body, request)
    host_key = ("", login_key[1])
    retry_after = max(
        _login_retry_after(login_key), _login_retry_after(host_key)
    )
    if retry_after:
        logger.warning("Login rate limited: username=%s retry_after=%ss", body.username, retry_after)
        raise HTTPException(
            status_code=429,
            detail="登录尝试过于频繁，请稍后再试",
            headers={"Retry-After": str(retry_after)},
        )
    result = await session.execute(select(User).where(User.username == body.username))
    user = result.scalar_one_or_none()
    if user is None or not verify_password(body.password, user.salt, user.password_hash):
        logger.warning("Login failed: username=%s reason=bad_credentials", body.username)
        retry_after = _record_login_failure(login_key)
        retry_after = max(
            retry_after,
            _record_login_failure(host_key, limit=_LOGIN_HOST_FAILURE_LIMIT),
        )
        if retry_after:
            raise HTTPException(
                status_code=429,
                detail="登录尝试过于频繁，请稍后再试",
                headers={"Retry-After": str(retry_after)},
            )
        raise HTTPException(status_code=401, detail="用户名或密码错误")
    _clear_login_failures(login_key)
    if user.status != "active":
        logger.info("Login blocked: user_id=%s username=%s status=%s", user.id, user.username, user.status)
        raise HTTPException(status_code=403, detail="账户已被停用")
    if user.salt != "bcrypt":
        user.password_hash, user.salt = hash_password(body.password)
    token = await _issue_session_token(user, session, request)
    await session.commit()
    logger.info(
        "Login succeeded: user_id=%s username=%s role=%s device=%s",
        user.id,
        user.username,
        user.role,
        _device_name(request),
    )
    return LoginResponse(token=token, id=user.id, is_admin=user.role == "admin",
                         role=user.role, username=user.username)


@router.post("/logout")
async def logout(
    authorization: str | None = Header(default=None),
    session: AsyncSession = Depends(get_session),
):
    token = _extract_bearer_token(authorization)
    auth_session = (
        await session.execute(
            select(UserSession).where(
                UserSession.token_hash == _token_hash(token),
                UserSession.revoked_at.is_(None),
            )
        )
    ).scalar_one_or_none()
    if auth_session is not None:
        auth_session.revoked_at = datetime.utcnow()
        await session.commit()
        logger.info("Logout: user_id=%s", auth_session.user_id)
    return {"message": "已退出登录"}


# ── User management ──────────────────────────────────────────────────────────

@router.get("/users")
async def list_users(current: User = Depends(require_admin),
                     session: AsyncSession = Depends(get_session)):
    result = await session.execute(select(User).order_by(User.created_at.desc()))
    users = result.scalars().all()
    return [{"id": u.id, "username": u.username, "role": u.role,
             "is_admin": u.role == "admin",
             "status": u.status, "created_at": str(u.created_at),
             "oauth_bound": bool(u.oauth_subject),
             "oauth_name": u.oauth_name or "",
             "oauth_user_id": u.oauth_user_id,
             "password_set": bool(u.password_set)} for u in users]


class CreateUserRequest(BaseModel):
    username: str = Field(min_length=2, max_length=128)
    password: str | None = Field(default=None, min_length=4, max_length=128)
    role: str = "user"
    nextmoe_user_id: int | None = None


@router.post("/users")
async def admin_create_user(body: CreateUserRequest,
                             current: User = Depends(require_admin),
                             session: AsyncSession = Depends(get_session)):
    if body.role not in ("admin", "user"):
        raise HTTPException(status_code=400, detail="无效的角色")
    if not body.password and body.nextmoe_user_id is None:
        raise HTTPException(
            status_code=400,
            detail="请至少设置密码或填写 NextMoe 用户 ID，否则该账户无法登录",
        )
    existing = await session.execute(select(User).where(User.username == body.username))
    if existing.scalar_one_or_none():
        raise HTTPException(status_code=409, detail="用户名已存在")
    nextmoe_user_id = body.nextmoe_user_id
    if nextmoe_user_id is not None:
        if nextmoe_user_id <= 0:
            raise HTTPException(status_code=400, detail="NextMoe 用户 ID 无效")
        taken = await session.execute(
            select(User).where(
                User.oauth_provider == "nextmoe",
                User.oauth_user_id == nextmoe_user_id,
            )
        )
        if taken.scalar_one_or_none():
            raise HTTPException(status_code=409, detail="该 NextMoe 用户 ID 已被使用")
    if body.password:
        pw_hash, salt = hash_password(body.password)
        password_set = True
    else:
        pw_hash, salt = hash_password(secrets.token_urlsafe(32))
        password_set = False
    role = body.role if body.role in ("admin", "user") else "user"
    user = User(
        username=body.username,
        password_hash=pw_hash,
        salt=salt,
        role=role,
        is_admin=role == "admin",
        status="active",
        password_set=password_set,
        oauth_provider="nextmoe" if nextmoe_user_id is not None else None,
        oauth_user_id=nextmoe_user_id,
    )
    session.add(user)
    try:
        await session.commit()
    except IntegrityError as exc:
        await session.rollback()
        detail = _integrity_conflict_detail(exc)
        if detail:
            raise HTTPException(status_code=409, detail=detail) from exc
        raise
    logger.info(
        "User created by admin: actor_id=%s user_id=%s username=%s role=%s oauth_linked=%s",
        current.id,
        user.id,
        user.username,
        role,
        nextmoe_user_id is not None,
    )
    return {"message": "创建成功", "user_id": user.id}


@router.put("/users/{user_id}")
async def admin_update_user(user_id: int, body: AdminUserUpdate,
                             current: User = Depends(require_admin),
                             session: AsyncSession = Depends(get_session)):
    result = await session.execute(select(User).where(User.id == user_id))
    user = result.scalar_one_or_none()
    if user is None:
        raise HTTPException(status_code=404, detail="用户不存在")

    # Resolve desired role (body.role takes priority over legacy body.is_admin)
    desired_role: str | None = body.role
    if desired_role is None and body.is_admin is not None:
        desired_role = "admin" if body.is_admin else "user"

    # Role change (all administrators are peers)
    if desired_role is not None and desired_role != user.role:
        if desired_role not in ("admin", "user"):
            raise HTTPException(status_code=400, detail="无效的角色")
        if desired_role == "user":
            await _ensure_not_last_admin(session, user)
        user.role = desired_role
        user.is_admin = desired_role == "admin"

    # Username/password
    if body.username and body.username != user.username:
        existing = await session.execute(select(User).where(User.username == body.username))
        if existing.scalar_one_or_none():
            raise HTTPException(status_code=409, detail="用户名已存在")
        user.username = body.username
    if body.password:
        pw_hash, salt = hash_password(body.password)
        user.password_hash = pw_hash
        user.salt = salt
        user.password_set = True
        await _revoke_user_sessions(user.id, session)

    if body.nextmoe_user_id is not None:
        if body.nextmoe_user_id <= 0:
            raise HTTPException(status_code=400, detail="NextMoe 用户 ID 无效")
        if user.oauth_user_id != body.nextmoe_user_id:
            taken = await session.execute(
                select(User).where(
                    User.oauth_provider == "nextmoe",
                    User.oauth_user_id == body.nextmoe_user_id,
                    User.id != user.id,
                )
            )
            if taken.scalar_one_or_none():
                raise HTTPException(
                    status_code=409, detail="该 NextMoe 用户 ID 已被使用"
                )
            user.oauth_provider = "nextmoe"
            user.oauth_user_id = body.nextmoe_user_id
            user.oauth_subject = None
            user.oauth_name = None
    elif body.clear_nextmoe:
        if user.role == "admin" and not user.password_set and not body.password:
            raise HTTPException(
                status_code=400,
                detail="该管理员没有密码，清除 NextMoe 绑定后将无法登录",
            )
        user.oauth_provider = None
        user.oauth_user_id = None
        user.oauth_subject = None
        user.oauth_name = None

    try:
        await session.commit()
    except IntegrityError as exc:
        await session.rollback()
        detail = _integrity_conflict_detail(exc)
        if detail:
            raise HTTPException(status_code=409, detail=detail) from exc
        raise
    changed = [
        name
        for name in ("username", "password", "role", "is_admin", "nextmoe_user_id")
        if getattr(body, name, None) is not None
    ]
    logger.info(
        "User updated by admin: actor_id=%s user_id=%s fields=%s role=%s",
        current.id,
        user.id,
        changed,
        user.role,
    )
    return {"message": "更新成功", "role": user.role}


@router.delete("/users/{user_id}")
async def admin_delete_user(user_id: int, current: User = Depends(require_admin),
                             session: AsyncSession = Depends(get_session)):
    result = await session.execute(select(User).where(User.id == user_id))
    user = result.scalar_one_or_none()
    if user is None:
        raise HTTPException(status_code=404, detail="用户不存在")
    if user.id == current.id:
        raise HTTPException(status_code=400, detail="不能删除自己的账户")
    await _ensure_not_last_admin(session, user)
    await _revoke_user_sessions(user.id, session)
    await session.delete(user)
    await session.commit()
    logger.info("User deleted: actor_id=%s user_id=%s", current.id, user_id)
    return {"message": "用户已删除"}


# ── Profile management ────────────────────────────────────────────────────────

class ProfileUpdate(BaseModel):
    username: str | None = None
    current_password: str | None = None
    new_password: str | None = None


@router.get("/profile/me")
async def get_my_profile(current: User = Depends(get_current_user),
                          session: AsyncSession = Depends(get_session)):
    from utils.log_identity import account_log_scope

    return {"id": current.id, "username": current.username,
            "role": current.role, "is_admin": current.role == "admin",
            "avatar_path": current.avatar_path,
            "password_set": bool(current.password_set),
            "oauth_bound": bool(current.oauth_subject),
            "log_scope": account_log_scope(current)}


@router.get("/profile/{user_id}")
async def get_profile(user_id: int, user: User = Depends(get_current_user),
                       session: AsyncSession = Depends(get_session)):
    result = await session.execute(select(User).where(User.id == user_id))
    profile_user = result.scalar_one_or_none()
    if profile_user is None:
        raise HTTPException(status_code=404, detail="User not found")
    return {"id": profile_user.id, "username": profile_user.username,
            "role": profile_user.role,
            "is_admin": profile_user.role == "admin",
            "avatar_path": profile_user.avatar_path,
            "password_set": bool(profile_user.password_set),
            "oauth_bound": bool(profile_user.oauth_subject)}


@router.put("/profile/{user_id}")
async def update_profile(user_id: int, body: ProfileUpdate,
                          request: Request,
                          current: User = Depends(get_current_user),
                          session: AsyncSession = Depends(get_session)):
    result = await session.execute(select(User).where(User.id == user_id))
    user = result.scalar_one_or_none()
    if user is None:
        raise HTTPException(status_code=404, detail="User not found")
    _ensure_profile_edit_access(current, user)
    new_token: str | None = None
    if body.new_password:
        if current.id == user.id and user.password_set:
            if not body.current_password:
                raise HTTPException(status_code=400, detail="需要当前密码")
            if not verify_password(body.current_password, user.salt, user.password_hash):
                raise HTTPException(status_code=403, detail="当前密码错误")
        pw_hash, salt = hash_password(body.new_password)
        user.password_hash = pw_hash
        user.salt = salt
        user.password_set = True
        await _revoke_user_sessions(user.id, session)
        if current.id == user.id:
            new_token = await _issue_session_token(user, session, request)
    if body.username and body.username != user.username:
        existing = await session.execute(select(User).where(User.username == body.username))
        if existing.scalar_one_or_none():
            raise HTTPException(status_code=409, detail="用户名已存在")
        user.username = body.username
    await session.commit()
    response: dict = {"message": "更新成功", "username": user.username}
    if new_token:
        response["new_token"] = new_token
    logger.info(
        "Profile updated: actor_id=%s user_id=%s username=%s password_changed=%s",
        current.id,
        user.id,
        user.username,
        body.new_password is not None,
    )
    return response


@router.post("/profile/{user_id}/avatar")
async def upload_avatar(user_id: int, file: UploadFile = File(...),
                         current: User = Depends(get_current_user),
                         session: AsyncSession = Depends(get_session)):
    from pathlib import Path
    from config import load_config
    result = await session.execute(select(User).where(User.id == user_id))
    user = result.scalar_one_or_none()
    if user is None:
        raise HTTPException(status_code=404, detail="User not found")
    _ensure_profile_edit_access(current, user)
    from utils.uploads import read_upload

    contents = await read_upload(file, limit=5 * 1024 * 1024, label="头像")
    ext = Path(file.filename or "avatar.jpg").suffix.lower()
    if ext not in {".jpg", ".jpeg", ".png", ".gif", ".webp"}:
        raise HTTPException(status_code=400, detail="File type not allowed")
    config = load_config()
    avatars_dir = Path(config.data_path) / "avatars"
    avatars_dir.mkdir(parents=True, exist_ok=True)
    import uuid
    name = f"{user_id}_{uuid.uuid4().hex[:8]}{ext}"
    dest = avatars_dir / name
    dest.write_bytes(contents)
    user.avatar_path = str(dest)
    await session.commit()
    logger.info(
        "Avatar uploaded: actor_id=%s user_id=%s file=%s",
        current.id,
        user.id,
        name,
    )
    return {"avatar_path": str(dest), "url": f"/api/files/avatars/{name}"}
