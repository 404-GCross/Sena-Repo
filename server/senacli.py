#!/usr/bin/env python3
"""Local maintenance CLI for Sena Repo server."""

from __future__ import annotations

import argparse
import asyncio
import sys
import time
from pathlib import Path

SERVER_DIR = Path(__file__).resolve().parent
if str(SERVER_DIR) not in sys.path:
    sys.path.insert(0, str(SERVER_DIR))

from cli.common import CliError, echo

SCRAPE_MODES = ("none", "missing", "overwrite", "metadata", "images")
CHANNELS = ("dev", "release")
RUN_TITLE = "bye~bye~"


def _add_password_options(parser: argparse.ArgumentParser) -> None:
    password = parser.add_mutually_exclusive_group()
    password.add_argument("--password", help="直接提供密码；会进入 shell 历史，不推荐")
    password.add_argument("--password-stdin", action="store_true", help="从 stdin 第一行读取密码")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="senacli",
        description="Sena Repo server local maintenance CLI",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    status = sub.add_parser("status", help="显示服务端、数据库、扫描和刮削状态")
    status.add_argument("--roots", action="store_true", help="同时显示根目录列表")

    scan = sub.add_parser("scan", help="扫描游戏库，可选扫描后刮削")
    scan.add_argument("--root-id", type=int, action="append", help="只扫描指定根目录，可重复")
    scan.add_argument(
        "--scrape",
        choices=SCRAPE_MODES,
        help="扫描完成后的刮削模式；不填则交互询问，非交互默认 none",
    )
    scan.add_argument("--sources", help="刮削源白名单，逗号分隔，例如 hikarinagi,vndb_kana")

    clear = sub.add_parser("clear", help="清空游戏条目后重新扫描")
    clear.add_argument("-f", "--force", action="store_true", help="跳过确认")
    clear.add_argument(
        "--scrape",
        choices=SCRAPE_MODES,
        help="重扫完成后的刮削模式；不填则交互询问，非交互默认 none",
    )
    clear.add_argument("--sources", help="刮削源白名单，逗号分隔，例如 hikarinagi,vndb_kana")

    backup = sub.add_parser("backup", help="备份 Steam 补丁匹配规则")
    backup.add_argument("-o", "--output", help="输出文件路径；默认保存到数据目录")

    restore = sub.add_parser("restore", help="恢复 Steam 补丁匹配规则")
    restore.add_argument("file", help="规则备份 JSON 文件")
    restore.add_argument("-y", "--yes", action="store_true", help="跳过确认")
    restore.add_argument("--replace", action="store_true", help="先清空当前规则再恢复")

    update = sub.add_parser("update", help="检查并更新裸机部署的服务端")
    update.add_argument("--channel", choices=CHANNELS, default="dev")
    update.add_argument("--ref", help="直接指定 Git ref，优先于 --channel")
    update.add_argument("--repo-url", help="直接指定 Git 仓库地址")
    update.add_argument("--force", action="store_true", help="即使版本相同也强制执行更新")
    update.add_argument("-y", "--yes", action="store_true", help="跳过确认")

    uninstall = sub.add_parser("uninstall", help="卸载裸机部署的服务端")
    data = uninstall.add_mutually_exclusive_group()
    data.add_argument("--purge-data", action="store_true", help="同时删除数据库与配置")
    data.add_argument("--keep-data", action="store_true", help="保留数据库与配置")

    useradd = sub.add_parser("useradd", help="本地创建用户")
    useradd.add_argument("username", nargs="?")
    useradd.add_argument("--admin", action="store_true", help="创建管理员；首个用户始终为服主")
    _add_password_options(useradd)

    username = sub.add_parser("username", help="修改用户名并踢出登录态")
    username.add_argument("user", nargs="?", help="用户 ID 或用户名；不填则交互选择")
    username.add_argument("new_username", nargs="?")

    passwd = sub.add_parser("passwd", help="修改密码并踢出登录态")
    passwd.add_argument("user", nargs="?", help="用户 ID 或用户名；不填则交互选择")
    _add_password_options(passwd)

    userdel = sub.add_parser("userdel", help="删除用户")
    userdel.add_argument("user", nargs="?", help="用户 ID 或用户名；不填则交互选择")
    userdel.add_argument("-f", "--force", action="store_true", help="跳过确认")

    useradmin = sub.add_parser("useradmin", help="升降管理员权限并踢出登录态")
    useradmin.add_argument("user", nargs="?", help="用户 ID 或用户名；不填则交互选择")
    role = useradmin.add_mutually_exclusive_group()
    role.add_argument("--admin", action="store_true", help="设为管理员")
    role.add_argument("--user", dest="regular_user", action="store_true", help="设为普通用户")
    useradmin.add_argument("-f", "--force", action="store_true", help="跳过确认")

    sub.add_parser("users", help="列出用户")
    sub.add_parser("run", help="???")
    return parser


def _type_print(text: str) -> None:
    for char in text:
        sys.stdout.write(char)
        sys.stdout.flush()
        time.sleep(0.035)
    sys.stdout.write("\n")
    sys.stdout.flush()
    time.sleep(0.8)


def _run_title_easter_egg() -> int:
    sys.stdout.write("\033[H\033[2J")
    sys.stdout.flush()
    time.sleep(1)
    _type_print(RUN_TITLE)
    return 0


async def dispatch(args: argparse.Namespace) -> int:
    if args.command == "run":
        return _run_title_easter_egg()
    if args.command in {"backup", "restore"}:
        from cli import steam_patch_rules

        if args.command == "backup":
            return steam_patch_rules.cmd_backup(args)
        return steam_patch_rules.cmd_restore(args)

    from cli import operations, users

    if args.command == "status":
        return await operations.cmd_status(args)
    if args.command == "scan":
        return await operations.cmd_scan(args)
    if args.command == "clear":
        return await operations.cmd_clear(args)
    if args.command == "update":
        return operations.cmd_update(args)
    if args.command == "uninstall":
        return operations.cmd_uninstall(args)
    if args.command == "useradd":
        return await users.cmd_useradd(args)
    if args.command == "username":
        return await users.cmd_username(args)
    if args.command == "passwd":
        return await users.cmd_passwd(args)
    if args.command == "userdel":
        return await users.cmd_userdel(args)
    if args.command == "useradmin":
        return await users.cmd_useradmin(args)
    if args.command == "users":
        return await users.cmd_users(args)
    raise CliError(f"Unknown command: {args.command}", 2)


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return asyncio.run(dispatch(args))
    except CliError as exc:
        if exc.code:
            echo(str(exc), err=True)
        return exc.code
    except KeyboardInterrupt:
        echo("已取消", err=True)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
