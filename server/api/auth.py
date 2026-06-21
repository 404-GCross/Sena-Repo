"""Auth API — login, register, admin approval, notifications."""

from __future__ import annotations

import secrets

from fastapi import APIRouter, Depends, File, Header, HTTPException, UploadFile
from pydantic import BaseModel, Field
from sqlalchemy import select, func
from sqlalchemy.ext.asyncio import AsyncSession

from database import get_session
from models.user import User, Notification, hash_password, verify_password


router = APIRouter(prefix="/api/auth", tags=["auth"])


# ── Auth dependencies ──

async def get_current_user(
    authorization: str | None = Header(default=None),
    session: AsyncSession = Depends(get_session),
) -> User:
    """Validate Bearer token and return current user.

    Supports both legacy tokens (plain user ID) and new random tokens.
    """
    if not authorization:
        raise HTTPException(status_code=401, detail="未登录")
    if not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="无效的认证格式")
    token = authorization.removeprefix("Bearer ")

    # Look up user by random token
    result = await session.execute(
        select(User).where(User.token == token, User.status == "active"))
    user = result.scalar_one_or_none()
    if user is None:
        raise HTTPException(status_code=401, detail="无效的令牌")
    return user


async def require_admin(
    user: User = Depends(get_current_user),
) -> User:
    """Require admin privileges."""
    if not user.is_admin:
        raise HTTPException(status_code=403, detail="需要管理员权限")
    return user


class LoginRequest(BaseModel):
    username: str
    password: str

class LoginResponse(BaseModel):
    token: str  # user id as simple token for now
    is_admin: bool
    username: str

class RegisterRequest(BaseModel):
    username: str = Field(min_length=2, max_length=128)
    password: str = Field(min_length=4, max_length=128)
    is_admin: bool = False  # false = regular user

class ApproveRequest(BaseModel):
    user_id: int
    approve: bool  # true = approve, false = reject


@router.post("/login", response_model=LoginResponse)
async def login(body: LoginRequest, session: AsyncSession = Depends(get_session)):
    result = await session.execute(
        select(User).where(User.username == body.username)
    )
    user = result.scalar_one_or_none()

    if user is None or not verify_password(body.password, user.salt, user.password_hash):
        raise HTTPException(status_code=401, detail="用户名或密码错误")

    if user.status == "pending":
        raise HTTPException(status_code=403, detail="账户等待管理员审批中")
    if user.status == "rejected":
        raise HTTPException(status_code=403, detail="账户已被拒绝")

    # Generate random token if not set (migration)
    if user.token is None:
        user.token = secrets.token_hex(32)
        await session.commit()
    return LoginResponse(
        token=user.token,
        is_admin=user.is_admin,
        username=user.username,
    )


@router.post("/register")
async def register(body: RegisterRequest, session: AsyncSession = Depends(get_session)):
    # Check if username exists
    existing = await session.execute(
        select(User).where(User.username == body.username)
    )
    if existing.scalar_one_or_none():
        raise HTTPException(status_code=409, detail="用户名已存在")

    # Count existing users. If 0, first user is auto-admin and auto-approved
    count = await session.execute(select(func.count()).select_from(User))
    is_first = count.scalar() == 0

    pw_hash, salt = hash_password(body.password)
    user = User(
        username=body.username,
        password_hash=pw_hash,
        salt=salt,
        is_admin=is_first or body.is_admin,
        status="active" if is_first else "pending",
        token=secrets.token_hex(32),
    )
    session.add(user)

    if not is_first:
        # Notify all admins about this registration
        admins = await session.execute(
            select(User).where(User.is_admin == True)
        )
        for admin in admins.scalars():
            session.add(Notification(
                type="approval_request",
                title=f"新用户注册: {body.username}",
                body=f"用户 {body.username} 申请{'管理员' if body.is_admin else '普通用户'}账户，等待审批",
                target_user_id=user.id,
            ))

    await session.commit()

    if is_first:
        return {"message": "注册成功，首个用户已自动激活", "user_id": user.id, "auto_approved": True}
    return {"message": "注册成功，等待管理员审批", "user_id": user.id, "pending": True}


@router.get("/users")
async def list_users(_admin: User = Depends(require_admin), session: AsyncSession = Depends(get_session)):
    """List all users."""
    result = await session.execute(
        select(User).order_by(User.created_at.desc())
    )
    users = result.scalars().all()
    return [{"id": u.id, "username": u.username, "is_admin": u.is_admin, "status": u.status, "created_at": str(u.created_at)} for u in users]


class CreateUserRequest(BaseModel):
    username: str = Field(min_length=2, max_length=128)
    password: str = Field(min_length=4, max_length=128)
    is_admin: bool = False


@router.post("/users")
async def create_user(body: CreateUserRequest, _admin: User = Depends(require_admin), session: AsyncSession = Depends(get_session)):
    """Admin creates a user directly (pre-approved)."""
    existing = await session.execute(
        select(User).where(User.username == body.username)
    )
    if existing.scalar_one_or_none():
        raise HTTPException(status_code=409, detail="用户名已存在")

    pw_hash, salt = hash_password(body.password)
    user = User(
        username=body.username,
        password_hash=pw_hash,
        salt=salt,
        is_admin=body.is_admin,
        status="active",
        token=secrets.token_hex(32),
    )
    session.add(user)
    await session.commit()
    await session.refresh(user)
    return {"id": user.id, "username": user.username, "message": "用户创建成功"}


@router.get("/pending")
async def list_pending(_admin: User = Depends(require_admin), session: AsyncSession = Depends(get_session)):
    """List users pending approval (admin only)."""
    result = await session.execute(
        select(User).where(User.status == "pending").order_by(User.created_at.desc())
    )
    users = result.scalars().all()
    return [{"id": u.id, "username": u.username, "is_admin": u.is_admin, "created_at": str(u.created_at)} for u in users]


@router.post("/approve")
async def approve_user(body: ApproveRequest, _admin: User = Depends(require_admin), session: AsyncSession = Depends(get_session)):
    """Approve or reject a pending user."""
    result = await session.execute(select(User).where(User.id == body.user_id))
    user = result.scalar_one_or_none()
    if user is None:
        raise HTTPException(status_code=404, detail="用户不存在")
    if user.status != "pending":
        raise HTTPException(status_code=400, detail="该用户不在待审批状态")

    user.status = "active" if body.approve else "rejected"

    # Mark related approval notification as read
    related = await session.execute(
        select(Notification).where(
            Notification.target_user_id == body.user_id,
            Notification.type == "approval_request",
        )
    )
    for n in related.scalars().all():
        n.read = True

    # Notification for the applicant
    session.add(Notification(
        type="approved" if body.approve else "rejected",
        title="账户已通过审批" if body.approve else "账户已被拒绝",
        body=f"你的账户申请{'已通过' if body.approve else '已被拒绝'}",
        target_user_id=user.id,
    ))

    await session.commit()
    return {"message": "操作成功"}


@router.get("/notifications")
async def list_notifications(user: User = Depends(get_current_user), session: AsyncSession = Depends(get_session)):
    """List recent notifications."""
    result = await session.execute(
        select(Notification).order_by(Notification.created_at.desc()).limit(50)
    )
    notes = result.scalars().all()
    return [{"id": n.id, "type": n.type, "title": n.title, "body": n.body,
             "target_user_id": n.target_user_id, "read": n.read, "created_at": str(n.created_at)}
            for n in notes]


@router.get("/notifications/unread-count")
async def unread_count(user: User = Depends(get_current_user), session: AsyncSession = Depends(get_session)):
    result = await session.execute(
        select(func.count()).select_from(Notification).where(Notification.read == False)
    )
    return {"count": result.scalar()}


@router.post("/notifications/{note_id}/read")
async def mark_read(note_id: int, user: User = Depends(get_current_user), session: AsyncSession = Depends(get_session)):
    result = await session.execute(select(Notification).where(Notification.id == note_id))
    note = result.scalar_one_or_none()
    if note:
        note.read = True
        await session.commit()
    return {"ok": True}


@router.post("/notifications/read-all")
async def mark_all_read(user: User = Depends(get_current_user), session: AsyncSession = Depends(get_session)):
    result = await session.execute(
        select(Notification).where(Notification.read == False)
    )
    for note in result.scalars().all():
        note.read = True
    await session.commit()
    return {"ok": True}


# ── Admin user management ──

class AdminUserUpdate(BaseModel):
    username: str | None = None
    password: str | None = None
    is_admin: bool | None = None


@router.put("/users/{user_id}")
async def admin_update_user(
    user_id: int, body: AdminUserUpdate, _admin: User = Depends(require_admin), session: AsyncSession = Depends(get_session),
):
    """Admin updates any user's info."""
    result = await session.execute(select(User).where(User.id == user_id))
    user = result.scalar_one_or_none()
    if user is None:
        raise HTTPException(status_code=404, detail="用户不存在")
    if body.username and body.username != user.username:
        existing = await session.execute(
            select(User).where(User.username == body.username)
        )
        if existing.scalar_one_or_none():
            raise HTTPException(status_code=409, detail="用户名已存在")
        user.username = body.username
    if body.password:
        pw_hash, salt = hash_password(body.password)
        user.password_hash = pw_hash
        user.salt = salt
    if body.is_admin is not None:
        user.is_admin = body.is_admin
    await session.commit()
    return {"message": "更新成功"}


@router.delete("/users/{user_id}")
async def admin_delete_user(
    user_id: int, _admin: User = Depends(require_admin), session: AsyncSession = Depends(get_session),
):
    """Admin deletes a user."""
    result = await session.execute(select(User).where(User.id == user_id))
    user = result.scalar_one_or_none()
    if user is None:
        raise HTTPException(status_code=404, detail="用户不存在")
    await session.delete(user)
    await session.commit()
    return {"message": "用户已删除"}


# ── Profile management ──

class ProfileUpdate(BaseModel):
    username: str | None = None
    current_password: str | None = None
    new_password: str | None = None


@router.get("/profile/me")
async def get_my_profile(
    current: User = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
):
    """Get current user profile from token."""
    return {
        "id": current.id, "username": current.username,
        "is_admin": current.is_admin, "avatar_path": current.avatar_path,
    }


@router.get("/profile/{user_id}")
async def get_profile(user_id: int, session: AsyncSession = Depends(get_session)):
    """Get user profile info."""
    result = await session.execute(select(User).where(User.id == user_id))
    user = result.scalar_one_or_none()
    if user is None:
        raise HTTPException(status_code=404, detail="User not found")
    return {
        "id": user.id, "username": user.username,
        "is_admin": user.is_admin, "avatar_path": user.avatar_path,
    }


@router.put("/profile/{user_id}")
async def update_profile(
    user_id: int, body: ProfileUpdate, current: User = Depends(get_current_user), session: AsyncSession = Depends(get_session),
):
    """Update username and/or password."""
    result = await session.execute(select(User).where(User.id == user_id))
    user = result.scalar_one_or_none()
    if user is None:
        raise HTTPException(status_code=404, detail="User not found")
    if current.id != user.id and not current.is_admin:
        raise HTTPException(status_code=403, detail="只能修改自己的资料")

    if body.new_password:
        if not body.current_password:
            raise HTTPException(status_code=400, detail="需要当前密码")
        if not verify_password(body.current_password, user.salt, user.password_hash):
            raise HTTPException(status_code=403, detail="当前密码错误")
        pw_hash, salt = hash_password(body.new_password)
        user.password_hash = pw_hash
        user.salt = salt

    if body.username and body.username != user.username:
        existing = await session.execute(
            select(User).where(User.username == body.username)
        )
        if existing.scalar_one_or_none():
            raise HTTPException(status_code=409, detail="用户名已存在")
        user.username = body.username

    await session.commit()
    return {"message": "更新成功", "username": user.username}


@router.post("/profile/{user_id}/avatar")
async def upload_avatar(
    user_id: int,
    file: UploadFile = File(...),
    current: User = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
):
    """Upload or update user avatar."""
    from pathlib import Path
    from config import load_config

    result = await session.execute(select(User).where(User.id == user_id))
    user = result.scalar_one_or_none()
    if user is None:
        raise HTTPException(status_code=404, detail="User not found")
    if current.id != user.id and not current.is_admin:
        raise HTTPException(status_code=403, detail="只能修改自己的头像")

    contents = await file.read()
    if len(contents) > 5 * 1024 * 1024:  # 5 MB limit
        raise HTTPException(status_code=400, detail="文件过大，最大 5MB")

    ext = Path(file.filename or "avatar.jpg").suffix.lower()
    if ext not in {".jpg", ".jpeg", ".png", ".gif", ".webp"}:
        raise HTTPException(status_code=403, detail="File type not allowed")

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
