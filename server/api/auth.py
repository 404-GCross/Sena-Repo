"""Auth API 鈥?login, register, admin approval, notifications."""

from __future__ import annotations

import secrets

from fastapi import APIRouter, Depends, File, Header, HTTPException, UploadFile
from pydantic import BaseModel, Field
from sqlalchemy import select, func
from sqlalchemy.ext.asyncio import AsyncSession
from fastapi import Request
from datetime import datetime, timedelta

from database import get_session
from models.user import User, Notification, hash_password, verify_password
from models.user import Session as DbSession


ACCESS_TOKEN_EXPIRE_MINUTES = 15
REFRESH_TOKEN_EXPIRE_DAYS = 7


def _create_tokens() -> tuple[str, str, datetime, datetime]:
    """Generate a new access/refresh token pair with expiry timestamps."""
    access_token = secrets.token_urlsafe(32)
    refresh_token = secrets.token_urlsafe(32)
    access_exp = datetime.utcnow() + timedelta(minutes=ACCESS_TOKEN_EXPIRE_MINUTES)
    refresh_exp = datetime.utcnow() + timedelta(days=REFRESH_TOKEN_EXPIRE_DAYS)
    return access_token, refresh_token, access_exp, refresh_exp


router = APIRouter(prefix="/api/auth", tags=["auth"])


# 鈹€鈹€ Auth dependencies 鈹€鈹€

async def get_current_user(
    authorization: str | None = Header(default=None),
    session: AsyncSession = Depends(get_session),
) -> User:
    """Validate Bearer access token and return current user."""
    if not authorization:
        raise HTTPException(status_code=401, detail="鏈櫥褰?)
    if not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="鏃犳晥鐨勮璇佹牸寮?)
    token = authorization.removeprefix("Bearer ")

    now = datetime.utcnow()
    result = await session.execute(
        select(DbSession).where(
            DbSession.access_token == token,
            DbSession.access_token_expires_at > now,
        )
    )
    db_session = result.scalar_one_or_none()
    if db_session is None:
        raise HTTPException(status_code=401, detail="浠ょ墝鏃犳晥鎴栧凡杩囨湡")

    db_session.last_used_at = now
    await session.commit()

    user_result = await session.execute(
        select(User).where(User.id == db_session.user_id, User.status == "active")
    )
    user = user_result.scalar_one_or_none()
    if user is None:
        raise HTTPException(status_code=401, detail="鐢ㄦ埛宸茶绂佺敤")
    return user


async def require_admin(
    user: User = Depends(get_current_user),
) -> User:
    """Require admin privileges."""
    if not user.is_admin:
        raise HTTPException(status_code=403, detail="闇€瑕佺鐞嗗憳鏉冮檺")
    return user


class LoginRequest(BaseModel):
    username: str
    password: str


class RefreshRequest(BaseModel):
    refresh_token: str


class LoginResponse(BaseModel):
    access_token: str
    refresh_token: str
    expires_in: int
    token_type: str = "Bearer"
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
async def login(
    body: LoginRequest,
    request: Request,
    session: AsyncSession = Depends(get_session),
):
    result = await session.execute(
        select(User).where(User.username == body.username)
    )
    user = result.scalar_one_or_none()

    if user is None or not verify_password(body.password, user.salt, user.password_hash):
        raise HTTPException(status_code=401, detail="鐢ㄦ埛鍚嶆垨瀵嗙爜閿欒")

    if user.status == "pending":
        raise HTTPException(status_code=403, detail="璐︽埛绛夊緟绠＄悊鍛樺鎵逛腑")
    if user.status == "rejected":
        raise HTTPException(status_code=403, detail="璐︽埛宸茶鎷掔粷")

    access_token, refresh_token, access_exp, refresh_exp = _create_tokens()

    db_session = DbSession(
        user_id=user.id,
        access_token=access_token,
        refresh_token=refresh_token,
        access_token_expires_at=access_exp,
        refresh_token_expires_at=refresh_exp,
        ip_address=request.client.host if request.client else None,
    )
    session.add(db_session)
    await session.commit()

    return LoginResponse(
        access_token=access_token,
        refresh_token=refresh_token,
        expires_in=ACCESS_TOKEN_EXPIRE_MINUTES * 60,
        is_admin=user.is_admin,
        username=user.username,
    )


@router.post("/refresh")
async def refresh(body: RefreshRequest, session: AsyncSession = Depends(get_session)):
    """Exchange a valid refresh token for a new access/refresh token pair."""
    now = datetime.utcnow()
    result = await session.execute(
        select(DbSession).where(
            DbSession.refresh_token == body.refresh_token,
            DbSession.refresh_token_expires_at > now,
        )
    )
    db_session = result.scalar_one_or_none()
    if db_session is None:
        raise HTTPException(status_code=401, detail="鍒锋柊浠ょ墝鏃犳晥鎴栧凡杩囨湡")

    access_token, refresh_token, access_exp, refresh_exp = _create_tokens()
    db_session.access_token = access_token
    db_session.refresh_token = refresh_token
    db_session.access_token_expires_at = access_exp
    db_session.refresh_token_expires_at = refresh_exp
    await session.commit()

    return {
        "access_token": access_token,
        "refresh_token": refresh_token,
        "expires_in": ACCESS_TOKEN_EXPIRE_MINUTES * 60,
        "token_type": "Bearer",
    }


@router.post("/logout")
async def logout(
    user: User = Depends(get_current_user),
    authorization: str | None = Header(default=None),
    session: AsyncSession = Depends(get_session),
):
    """Invalidate current access token (logout this device)."""
    token = authorization.removeprefix("Bearer ") if authorization else ""
    result = await session.execute(
        select(DbSession).where(DbSession.access_token == token)
    )
    db_session = result.scalar_one_or_none()
    if db_session:
        await session.delete(db_session)
        await session.commit()
    return {"message": "宸茬櫥鍑?}


@router.post("/logout-all")
async def logout_all(
    user: User = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
):
    """Invalidate all sessions for the current user."""
    result = await session.execute(
        select(DbSession).where(DbSession.user_id == user.id)
    )
    for s in result.scalars().all():
        await session.delete(s)
    await session.commit()
    return {"message": "宸茬櫥鍑烘墍鏈夎澶?}


@router.post("/register")
async def register(body: RegisterRequest, session: AsyncSession = Depends(get_session)):
    # Check if username exists
    existing = await session.execute(
        select(User).where(User.username == body.username)
    )
    if existing.scalar_one_or_none():
        raise HTTPException(status_code=409, detail="鐢ㄦ埛鍚嶅凡瀛樺湪")

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
        # token removed (now in sessions table)
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
                title=f"鏂扮敤鎴锋敞鍐? {body.username}",
                body=f"鐢ㄦ埛 {body.username} 鐢宠{'绠＄悊鍛? if body.is_admin else '鏅€氱敤鎴?}璐︽埛锛岀瓑寰呭鎵?,
                target_user_id=user.id,
            ))

    await session.commit()

    if is_first:
        return {"message": "娉ㄥ唽鎴愬姛锛岄涓敤鎴峰凡鑷姩婵€娲?, "user_id": user.id, "auto_approved": True}
    return {"message": "娉ㄥ唽鎴愬姛锛岀瓑寰呯鐞嗗憳瀹℃壒", "user_id": user.id, "pending": True}


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
        raise HTTPException(status_code=409, detail="鐢ㄦ埛鍚嶅凡瀛樺湪")

    pw_hash, salt = hash_password(body.password)
    user = User(
        username=body.username,
        password_hash=pw_hash,
        salt=salt,
        is_admin=body.is_admin,
        status="active",
        # token removed (now in sessions table)
    )
    session.add(user)
    await session.commit()
    await session.refresh(user)
    return {"id": user.id, "username": user.username, "message": "鐢ㄦ埛鍒涘缓鎴愬姛"}


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
        raise HTTPException(status_code=404, detail="鐢ㄦ埛涓嶅瓨鍦?)
    if user.status != "pending":
        raise HTTPException(status_code=400, detail="璇ョ敤鎴蜂笉鍦ㄥ緟瀹℃壒鐘舵€?)

    user.status = "active" if body.approve else "rejected"
    # Prevent self-service admin escalation 鈥?approval always resets to regular user
    if body.approve:
        user.is_admin = False

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
        title="璐︽埛宸查€氳繃瀹℃壒" if body.approve else "璐︽埛宸茶鎷掔粷",
        body=f"浣犵殑璐︽埛鐢宠{'宸查€氳繃' if body.approve else '宸茶鎷掔粷'}",
        target_user_id=user.id,
    ))

    await session.commit()
    return {"message": "鎿嶄綔鎴愬姛"}


@router.get("/notifications")
async def list_notifications(user: User = Depends(get_current_user), session: AsyncSession = Depends(get_session)):
    """List recent notifications (admins see all, users see their own)."""
    query = select(Notification).order_by(Notification.created_at.desc()).limit(50)
    if not user.is_admin:
        query = query.where(Notification.target_user_id == user.id)
    result = await session.execute(query)
    notes = result.scalars().all()
    return [{"id": n.id, "type": n.type, "title": n.title, "body": n.body,
             "target_user_id": n.target_user_id, "read": n.read, "created_at": str(n.created_at)}
            for n in notes]


@router.get("/notifications/unread-count")
async def unread_count(user: User = Depends(get_current_user), session: AsyncSession = Depends(get_session)):
    query = select(func.count()).select_from(Notification).where(Notification.read == False)
    if not user.is_admin:
        query = query.where(Notification.target_user_id == user.id)
    result = await session.execute(query)
    return {"count": result.scalar()}


@router.post("/notifications/{note_id}/read")
async def mark_read(note_id: int, user: User = Depends(get_current_user), session: AsyncSession = Depends(get_session)):
    query = select(Notification).where(Notification.id == note_id)
    if not user.is_admin:
        query = query.where(Notification.target_user_id == user.id)
    result = await session.execute(query)
    note = result.scalar_one_or_none()
    if note:
        note.read = True
        await session.commit()
    return {"ok": True}


@router.post("/notifications/read-all")
async def mark_all_read(user: User = Depends(get_current_user), session: AsyncSession = Depends(get_session)):
    query = select(Notification).where(Notification.read == False)
    if not user.is_admin:
        query = query.where(Notification.target_user_id == user.id)
    result = await session.execute(query)
    for note in result.scalars().all():
        note.read = True
    await session.commit()
    return {"ok": True}


# 鈹€鈹€ Admin user management 鈹€鈹€

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
        raise HTTPException(status_code=404, detail="鐢ㄦ埛涓嶅瓨鍦?)
    if body.username and body.username != user.username:
        existing = await session.execute(
            select(User).where(User.username == body.username)
        )
        if existing.scalar_one_or_none():
            raise HTTPException(status_code=409, detail="鐢ㄦ埛鍚嶅凡瀛樺湪")
        user.username = body.username
    if body.password:
        pw_hash, salt = hash_password(body.password)
        user.password_hash = pw_hash
        user.salt = salt
        # Invalidate all existing sessions for this user
        sess_result = await session.execute(
            select(DbSession).where(DbSession.user_id == user.id)
        )
        for s in sess_result.scalars().all():
            await session.delete(s)
    if body.is_admin is not None:
        user.is_admin = body.is_admin
    await session.commit()
    return {"message": "鏇存柊鎴愬姛"}


@router.delete("/users/{user_id}")
async def admin_delete_user(
    user_id: int, _admin: User = Depends(require_admin), session: AsyncSession = Depends(get_session),
):
    """Admin deletes a user."""
    result = await session.execute(select(User).where(User.id == user_id))
    user = result.scalar_one_or_none()
    if user is None:
        raise HTTPException(status_code=404, detail="鐢ㄦ埛涓嶅瓨鍦?)
    # Also delete all sessions for this user
    sess_result = await session.execute(
        select(DbSession).where(DbSession.user_id == user_id)
    )
    for s in sess_result.scalars().all():
        await session.delete(s)
    await session.delete(user)
    await session.commit()
    return {"message": "鐢ㄦ埛宸插垹闄?}


# 鈹€鈹€ Profile management 鈹€鈹€

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
async def get_profile(user_id: int, user: User = Depends(get_current_user), session: AsyncSession = Depends(get_session)):
    """Get user profile info (authenticated users only)."""
    result = await session.execute(select(User).where(User.id == user_id))
    profile_user = result.scalar_one_or_none()
    if profile_user is None:
        raise HTTPException(status_code=404, detail="User not found")
    return {
        "id": profile_user.id, "username": profile_user.username,
        "is_admin": profile_user.is_admin, "avatar_path": profile_user.avatar_path,
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
        raise HTTPException(status_code=403, detail="鍙兘淇敼鑷繁鐨勮祫鏂?)

    if body.new_password:
        if not body.current_password:
            raise HTTPException(status_code=400, detail="闇€瑕佸綋鍓嶅瘑鐮?)
        if not verify_password(body.current_password, user.salt, user.password_hash):
            raise HTTPException(status_code=403, detail="褰撳墠瀵嗙爜閿欒")
        pw_hash, salt = hash_password(body.new_password)
        user.password_hash = pw_hash
        user.salt = salt
        # Invalidate all existing sessions for this user (force re-login)
        sess_result = await session.execute(
            select(DbSession).where(DbSession.user_id == user.id)
        )
        for s in sess_result.scalars().all():
            await session.delete(s)

    if body.username and body.username != user.username:
        existing = await session.execute(
            select(User).where(User.username == body.username)
        )
        if existing.scalar_one_or_none():
            raise HTTPException(status_code=409, detail="鐢ㄦ埛鍚嶅凡瀛樺湪")
        user.username = body.username

    await session.commit()
    return {"message": "鏇存柊鎴愬姛", "username": user.username}


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
        raise HTTPException(status_code=403, detail="鍙兘淇敼鑷繁鐨勫ご鍍?)

    contents = await file.read()
    if len(contents) > 5 * 1024 * 1024:  # 5 MB limit
        raise HTTPException(status_code=400, detail="鏂囦欢杩囧ぇ锛屾渶澶?5MB")

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
