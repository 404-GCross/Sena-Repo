"""Local user-management commands for senacli."""

from __future__ import annotations

import sys
from datetime import datetime

import database as db
from cli.common import (
    CliError,
    choose,
    confirm,
    confirm_phrase,
    echo,
    fail,
    is_interactive,
    prepare_app,
    print_table,
    prompt_password_twice,
    prompt_text,
)
from models.user import User, UserSession, hash_password
from sqlalchemy import delete, func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession


def _display_role(role: str | None) -> str:
    return role or "user"


def _display_status(status: str | None) -> str:
    return status or "active"


def _read_password(args) -> str:
    if getattr(args, "password", None) and getattr(args, "password_stdin", False):
        fail("--password and --password-stdin cannot be used together", 2)
    if getattr(args, "password_stdin", False):
        password = sys.stdin.readline().rstrip("\r\n")
    elif getattr(args, "password", None):
        password = args.password
    else:
        password = prompt_password_twice()
    if len(password) < 4:
        fail("密码至少需要 4 位", 2)
    return password


async def _revoke_sessions(session: AsyncSession, user_id: int) -> int:
    now = datetime.utcnow()
    result = await session.execute(
        select(UserSession).where(
            UserSession.user_id == user_id,
            UserSession.revoked_at.is_(None),
        )
    )
    sessions = list(result.scalars().all())
    for auth_session in sessions:
        auth_session.revoked_at = now
    return len(sessions)


async def _find_user(session: AsyncSession, identifier: str) -> User | None:
    value = str(identifier).strip()
    if value.isdigit():
        result = await session.execute(select(User).where(User.id == int(value)))
        user = result.scalar_one_or_none()
        if user is not None:
            return user
    result = await session.execute(select(User).where(User.username == value))
    return result.scalar_one_or_none()


async def _select_user(session: AsyncSession, identifier: str | None) -> User:
    if identifier:
        user = await _find_user(session, identifier)
        if user is None:
            fail(f"用户不存在: {identifier}", 3)
        return user

    result = await session.execute(select(User).order_by(User.id))
    users = list(result.scalars().all())
    if not users:
        fail("当前没有用户", 3)
    if not is_interactive():
        fail("non-interactive mode requires a user id or username", 2)

    selected = choose(
        "选择用户",
        [
            (
                str(user.id),
                f"{user.username} / {_display_role(user.role)} / {_display_status(user.status)}",
            )
            for user in users
        ],
    )
    user = await _find_user(session, selected)
    if user is None:
        fail("选择的用户不存在", 3)
    return user


async def cmd_useradd(args) -> int:
    await prepare_app()
    async with db._session_factory() as session:
        username = args.username or prompt_text("用户名")
        password = _read_password(args)
        count = int(
            (await session.execute(select(func.count()).select_from(User))).scalar_one() or 0
        )
        role = "owner" if count == 0 else ("admin" if args.admin else "user")
        existing = await session.execute(select(User).where(User.username == username))
        if existing.scalar_one_or_none():
            fail(f"用户名已存在: {username}", 4)
        pw_hash, salt = hash_password(password)
        user = User(
            username=username,
            password_hash=pw_hash,
            salt=salt,
            role=role,
            is_admin=role in ("owner", "admin"),
            status="active",
        )
        session.add(user)
        try:
            await session.commit()
        except IntegrityError as exc:
            await session.rollback()
            raise CliError("创建用户失败：用户名重复或服主已存在", 4) from exc
        await session.refresh(user)
        echo(f"已创建用户: {user.username} (id={user.id}, role={user.role})")
    return 0


async def cmd_username(args) -> int:
    await prepare_app()
    async with db._session_factory() as session:
        user = await _select_user(session, args.user)
        new_username = args.new_username or prompt_text("新用户名", default=user.username)
        if new_username == user.username:
            echo("用户名未变化")
            return 0
        existing = await session.execute(
            select(User).where(User.username == new_username, User.id != user.id)
        )
        if existing.scalar_one_or_none():
            fail(f"用户名已存在: {new_username}", 4)
        old_username = user.username
        user.username = new_username
        revoked = await _revoke_sessions(session, user.id)
        await session.commit()
        echo(f"已修改用户名: {old_username} -> {new_username}；已踢出 {revoked} 个会话")
    return 0


async def cmd_passwd(args) -> int:
    await prepare_app()
    async with db._session_factory() as session:
        user = await _select_user(session, args.user)
        password = _read_password(args)
        user.password_hash, user.salt = hash_password(password)
        revoked = await _revoke_sessions(session, user.id)
        await session.commit()
        echo(f"已修改密码: {user.username}；已踢出 {revoked} 个会话")
    return 0


async def cmd_userdel(args) -> int:
    await prepare_app()
    async with db._session_factory() as session:
        user = await _select_user(session, args.user)
        if user.role == "owner":
            fail("不能删除服主账户；如需更换服主请先转让或使用 set_owner.py", 4)
        if not args.force:
            if not confirm(f"确认删除用户 {user.username}？"):
                echo("已取消")
                return 130
            if not confirm_phrase(
                f"这会删除用户 {user.username} 并使其所有登录态失效。",
                user.username,
            ):
                echo("已取消")
                return 130
        username = user.username
        user_id = user.id
        await session.execute(delete(UserSession).where(UserSession.user_id == user_id))
        await session.delete(user)
        await session.commit()
        echo(f"已删除用户: {username} (id={user_id})")
    return 0


async def cmd_useradmin(args) -> int:
    await prepare_app()
    async with db._session_factory() as session:
        user = await _select_user(session, args.user)
        if user.role == "owner":
            fail("不能通过 useradmin 修改服主角色", 4)

        if args.admin:
            desired_role = "admin"
        elif args.regular_user:
            desired_role = "user"
        else:
            desired_role = "user" if user.role == "admin" else "admin"

        if user.role == desired_role:
            echo(f"用户 {user.username} 已经是 {desired_role}")
            return 0
        if not args.force and not confirm(
            f"确认将 {user.username} 从 {_display_role(user.role)} 改为 {desired_role}？"
        ):
            echo("已取消")
            return 130

        user.role = desired_role
        user.is_admin = desired_role == "admin"
        user.status = "active"
        revoked = await _revoke_sessions(session, user.id)
        await session.commit()
        echo(f"已更新角色: {user.username} -> {desired_role}；已踢出 {revoked} 个会话")
    return 0


async def cmd_users(args) -> int:
    await prepare_app()
    async with db._session_factory() as session:
        result = await session.execute(select(User).order_by(User.id))
        users = list(result.scalars().all())
        rows = []
        for user in users:
            active_sessions = int(
                (
                    await session.execute(
                        select(func.count())
                        .select_from(UserSession)
                        .where(
                            UserSession.user_id == user.id,
                            UserSession.revoked_at.is_(None),
                        )
                    )
                ).scalar_one()
                or 0
            )
            rows.append(
                [
                    user.id,
                    user.username,
                    _display_role(user.role),
                    _display_status(user.status),
                    active_sessions,
                ]
            )
        print_table(["ID", "Username", "Role", "Status", "Sessions"], rows)
    return 0
