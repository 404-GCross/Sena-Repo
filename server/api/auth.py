"""Auth API - login, register, user management with owner/admin/user roles."""

from __future__ import annotations
import secrets
from datetime import datetime, timedelta

from fastapi import APIRouter, Depends, File, Header, HTTPException, UploadFile
from pydantic import BaseModel, Field
from sqlalchemy import select, func
from sqlalchemy.ext.asyncio import AsyncSession

from config import load_config
from database import get_session
from models.user import User, Notification, hash_password, verify_password

router = APIRouter(prefix="/api/auth", tags=["auth"])


def _token_expires_at() -> datetime:
    days = max(1, load_config().server.token_expire_days)
    return datetime.utcnow() + timedelta(days=days)


def _issue_token(user: User) -> None:
    user.token = secrets.token_hex(32)
    user.token_expires_at = _token_expires_at()


# ── Auth dependencies ───────────────────────────────────────────────────────

async def get_current_user(
    authorization: str | None = Header(default=None),
    session: AsyncSession = Depends(get_session),
) -> User:
    if not authorization:
        raise HTTPException(status_code=401, detail="未登录")
    if not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="无效的认证格式")
    token = authorization.removeprefix("Bearer ")
    result = await session.execute(
        select(User).where(User.token == token, User.status == "active"))
    user = result.scalar_one_or_none()
    if user is None:
        raise HTTPException(status_code=401, detail="令牌无效或已过期")
    now = datetime.utcnow()
    if user.token_expires_at is None:
        user.token_expires_at = _token_expires_at()
        await session.commit()
    elif user.token_expires_at <= now:
        user.token = None
        user.token_expires_at = None
        await session.commit()
        raise HTTPException(status_code=401, detail="令牌无效或已过期")
    return user


async def require_admin(user: User = Depends(get_current_user)) -> User:
    """Require admin or owner privileges."""
    if user.role not in ("owner", "admin"):
        raise HTTPException(status_code=403, detail="需要管理员权限")
    return user


async def require_owner(user: User = Depends(get_current_user)) -> User:
    """Require owner privilege."""
    if user.role != "owner":
        raise HTTPException(status_code=403, detail="需要服主权限")
    return user


# ── Schemas ─────────────────────────────────────────────────────────────────

class LoginRequest(BaseModel):
    username: str
    password: str


class LoginResponse(BaseModel):
    token: str
    is_admin: bool
    role: str
    username: str


class RegisterRequest(BaseModel):
    username: str = Field(min_length=2, max_length=128)
    password: str = Field(min_length=4, max_length=128)


class ApproveRequest(BaseModel):
    user_id: int
    approve: bool


class AdminUserUpdate(BaseModel):
    username: str | None = None
    password: str | None = None
    is_admin: bool | None = None   # legacy; ignored if role is set
    role: str | None = None        # owner | admin | user (owner-only for admin/owner targets)


# ── Auth endpoints ───────────────────────────────────────────────────────────

@router.post("/login", response_model=LoginResponse)
async def login(body: LoginRequest, session: AsyncSession = Depends(get_session)):
    result = await session.execute(select(User).where(User.username == body.username))
    user = result.scalar_one_or_none()
    if user is None or not verify_password(body.password, user.salt, user.password_hash):
        raise HTTPException(status_code=401, detail="用户名或密码错误")
    if user.status == "pending":
        raise HTTPException(status_code=403, detail="账户等待管理员审批中")
    if user.status == "rejected":
        raise HTTPException(status_code=403, detail="账户已被拒绝")
    if user.salt != "bcrypt":
        user.password_hash, user.salt = hash_password(body.password)
    _issue_token(user)
    await session.commit()
    return LoginResponse(token=user.token, is_admin=user.role in ("owner", "admin"),
                         role=user.role, username=user.username)


@router.post("/register")
async def register(body: RegisterRequest, session: AsyncSession = Depends(get_session)):
    existing = await session.execute(select(User).where(User.username == body.username))
    if existing.scalar_one_or_none():
        raise HTTPException(status_code=409, detail="用户名已存在")
    count = await session.execute(select(func.count()).select_from(User))
    is_first = count.scalar() == 0
    pw_hash, salt = hash_password(body.password)
    role = "owner" if is_first else "user"
    user = User(
        username=body.username, password_hash=pw_hash, salt=salt,
        role=role, is_admin=is_first,
        status="active" if is_first else "pending",
    )
    _issue_token(user)
    session.add(user)
    await session.flush()
    if not is_first:
        admins = await session.execute(
            select(User).where(User.role.in_(("owner", "admin")))
        )
        for admin in admins.scalars():
            session.add(Notification(
                type="approval_request",
                title=f"新用户注册: {body.username}",
                body=f"用户 {body.username} 申请普通用户账户，等待审批",
                target_user_id=user.id,
            ))
    await session.commit()
    if is_first:
        return {"message": "注册成功，首个用户已成为服主", "user_id": user.id, "auto_approved": True}
    return {"message": "注册成功，等待管理员审批", "user_id": user.id, "pending": True}


# ── User management ──────────────────────────────────────────────────────────

@router.get("/users")
async def list_users(current: User = Depends(require_admin),
                     session: AsyncSession = Depends(get_session)):
    result = await session.execute(select(User).order_by(User.created_at.desc()))
    users = result.scalars().all()
    return [{"id": u.id, "username": u.username, "role": u.role,
             "is_admin": u.role in ("owner", "admin"),
             "status": u.status, "created_at": str(u.created_at)} for u in users]


class CreateUserRequest(BaseModel):
    username: str = Field(min_length=2, max_length=128)
    password: str = Field(min_length=4, max_length=128)
    role: str = "user"


@router.post("/users")
async def admin_create_user(body: CreateUserRequest,
                             current: User = Depends(require_admin),
                             session: AsyncSession = Depends(get_session)):
    # Only owner can create admins directly
    if body.role in ("owner", "admin") and current.role != "owner":
        raise HTTPException(status_code=403, detail="只有服主可以创建管理员")
    if body.role == "owner":
        raise HTTPException(status_code=400, detail="不能直接创建服主，请通过转让功能")
    existing = await session.execute(select(User).where(User.username == body.username))
    if existing.scalar_one_or_none():
        raise HTTPException(status_code=409, detail="用户名已存在")
    pw_hash, salt = hash_password(body.password)
    role = body.role if body.role in ("admin", "user") else "user"
    user = User(username=body.username, password_hash=pw_hash, salt=salt,
                role=role, is_admin=role == "admin", status="active")
    _issue_token(user)
    session.add(user)
    await session.commit()
    return {"message": "创建成功", "user_id": user.id}


@router.post("/approve")
async def approve_user(body: ApproveRequest,
                       current: User = Depends(require_admin),
                       session: AsyncSession = Depends(get_session)):
    result = await session.execute(select(User).where(User.id == body.user_id))
    user = result.scalar_one_or_none()
    if user is None:
        raise HTTPException(status_code=404, detail="用户不存在")
    if user.status != "pending":
        raise HTTPException(status_code=400, detail="用户状态不是待审批")
    user.status = "active" if body.approve else "rejected"
    if body.approve:
        if user.token is None:
            _issue_token(user)
        else:
            user.token_expires_at = _token_expires_at()
        session.add(Notification(
            type="approved", title="账户已通过审批",
            body="你的账户申请已通过", target_user_id=user.id,
        ))
    else:
        session.add(Notification(
            type="rejected", title="账户已被拒绝",
            body="你的账户申请已被拒绝", target_user_id=user.id,
        ))
    # mark approval request notification read
    notifs = await session.execute(
        select(Notification).where(
            Notification.type == "approval_request",
            Notification.target_user_id == user.id,
        )
    )
    for n in notifs.scalars():
        n.read = True
    await session.commit()
    return {"message": "已通过" if body.approve else "已拒绝"}


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

    # Admin can only manage regular users; cannot change roles
    if current.role == "admin":
        if user.role != "user":
            raise HTTPException(status_code=403, detail="管理员只能管理普通用户")
        if desired_role is not None and desired_role != "user":
            raise HTTPException(status_code=403, detail="管理员无权修改用户角色")

    # Role change (owner only)
    if desired_role is not None and desired_role != user.role:
        if desired_role not in ("owner", "admin", "user"):
            raise HTTPException(status_code=400, detail="无效的角色")
        if desired_role == "owner":
            if user.id == current.id:
                raise HTTPException(status_code=400, detail="您已是服主")
            # Transfer ownership: current owner steps down to admin
            current.role = "admin"
            current.is_admin = True
            user.role = "owner"
            user.is_admin = True
        elif desired_role == "admin":
            if user.role == "owner":
                raise HTTPException(status_code=400, detail="不能直接修改服主角色，请通过转让功能")
            user.role = "admin"
            user.is_admin = True
        elif desired_role == "user":
            if user.role == "owner":
                raise HTTPException(status_code=400, detail="不能直接降级服主，请先转让服主身份")
            user.role = "user"
            user.is_admin = False

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

    await session.commit()
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
    if user.role == "owner":
        raise HTTPException(status_code=403, detail="不能删除服主账户")
    if current.role == "admin" and user.role != "user":
        raise HTTPException(status_code=403, detail="管理员只能删除普通用户")
    await session.delete(user)
    await session.commit()
    return {"message": "用户已删除"}


# ── Notifications ────────────────────────────────────────────────────────────

@router.get("/notifications")
async def get_notifications(current: User = Depends(get_current_user),
                             session: AsyncSession = Depends(get_session)):
    query = select(Notification).order_by(Notification.created_at.desc())
    if not current.role in ("owner", "admin"):
        query = query.where(Notification.target_user_id == current.id)
    result = await session.execute(query)
    notifs = result.scalars().all()
    return [{"id": n.id, "type": n.type, "title": n.title, "body": n.body,
             "read": n.read, "target_user_id": n.target_user_id,
             "created_at": str(n.created_at)} for n in notifs]


@router.get("/notifications/unread-count")
async def unread_notification_count(current: User = Depends(get_current_user),
                                     session: AsyncSession = Depends(get_session)):
    query = select(func.count()).select_from(Notification).where(Notification.read == False)
    if not current.role in ("owner", "admin"):
        query = query.where(Notification.target_user_id == current.id)
    result = await session.execute(query)
    return {"count": result.scalar()}


@router.put("/notifications/{notif_id}/read")
async def mark_notification_read(notif_id: int, current: User = Depends(get_current_user),
                                   session: AsyncSession = Depends(get_session)):
    result = await session.execute(select(Notification).where(Notification.id == notif_id))
    notif = result.scalar_one_or_none()
    if notif is None:
        raise HTTPException(status_code=404, detail="通知不存在")
    notif.read = True
    await session.commit()
    return {"message": "已标记已读"}


@router.put("/notifications/read-all")
async def mark_all_notifications_read(current: User = Depends(get_current_user),
                                        session: AsyncSession = Depends(get_session)):
    query = select(Notification).where(Notification.read == False)
    if not current.role in ("owner", "admin"):
        query = query.where(Notification.target_user_id == current.id)
    result = await session.execute(query)
    for n in result.scalars():
        n.read = True
    await session.commit()
    return {"message": "全部已读"}


# ── Profile management ────────────────────────────────────────────────────────

class ProfileUpdate(BaseModel):
    username: str | None = None
    current_password: str | None = None
    new_password: str | None = None


@router.get("/profile/me")
async def get_my_profile(current: User = Depends(get_current_user),
                          session: AsyncSession = Depends(get_session)):
    return {"id": current.id, "username": current.username,
            "role": current.role, "is_admin": current.role in ("owner", "admin"),
            "avatar_path": current.avatar_path}


@router.get("/profile/{user_id}")
async def get_profile(user_id: int, user: User = Depends(get_current_user),
                       session: AsyncSession = Depends(get_session)):
    result = await session.execute(select(User).where(User.id == user_id))
    profile_user = result.scalar_one_or_none()
    if profile_user is None:
        raise HTTPException(status_code=404, detail="User not found")
    return {"id": profile_user.id, "username": profile_user.username,
            "role": profile_user.role,
            "is_admin": profile_user.role in ("owner", "admin"),
            "avatar_path": profile_user.avatar_path}


@router.put("/profile/{user_id}")
async def update_profile(user_id: int, body: ProfileUpdate,
                          current: User = Depends(get_current_user),
                          session: AsyncSession = Depends(get_session)):
    result = await session.execute(select(User).where(User.id == user_id))
    user = result.scalar_one_or_none()
    if user is None:
        raise HTTPException(status_code=404, detail="User not found")
    if current.id != user.id and current.role not in ("owner", "admin"):
        raise HTTPException(status_code=403, detail="只能修改自己的资料")
    if body.new_password:
        if current.id == user.id:
            if not body.current_password:
                raise HTTPException(status_code=400, detail="需要当前密码")
            if not verify_password(body.current_password, user.salt, user.password_hash):
                raise HTTPException(status_code=403, detail="当前密码错误")
        elif current.role not in ("owner", "admin"):
            raise HTTPException(status_code=403, detail="无权修改他人密码")
        pw_hash, salt = hash_password(body.new_password)
        user.password_hash = pw_hash
        user.salt = salt
        _issue_token(user)
    if body.username and body.username != user.username:
        existing = await session.execute(select(User).where(User.username == body.username))
        if existing.scalar_one_or_none():
            raise HTTPException(status_code=409, detail="用户名已存在")
        user.username = body.username
    await session.commit()
    response: dict = {"message": "更新成功", "username": user.username}
    if body.new_password:
        response["new_token"] = user.token
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
    if current.id != user.id and current.role not in ("owner", "admin"):
        raise HTTPException(status_code=403, detail="只能修改自己的头像")
    contents = await file.read()
    if len(contents) > 5 * 1024 * 1024:
        raise HTTPException(status_code=400, detail="文件过大，最大5MB")
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
    return {"avatar_path": str(dest), "url": f"/api/files/avatars/{name}"}
