"""Shared helpers for senacli."""

from __future__ import annotations

import os
import subprocess
import sys
from getpass import getpass
from pathlib import Path
from typing import Iterable, Sequence, TYPE_CHECKING

if TYPE_CHECKING:
    from config import Config


SERVER_DIR = Path(__file__).resolve().parents[1]
DEFAULT_SERVICE_NAME = "sena-repo"
DEFAULT_ENV_FILE = Path("/etc/sena-repo/sena-repo.env")

# Package managers that own the service lifecycle for a deployment. senacli
# refuses update/uninstall on those because the manager must do it.
MANAGED_DEPLOYMENTS = {"fnos": "飞牛应用中心"}


class CliError(Exception):
    def __init__(self, message: str, code: int = 1):
        super().__init__(message)
        self.code = code


def echo(message: str = "", *, err: bool = False) -> None:
    print(message, file=sys.stderr if err else sys.stdout)


def fail(message: str, code: int = 1) -> None:
    raise CliError(message, code)


def is_interactive() -> bool:
    return sys.stdin.isatty() and sys.stdout.isatty()


def load_environment_file() -> None:
    env_path = Path(os.environ.get("SENA_ENV_FILE", str(DEFAULT_ENV_FILE)))
    if not env_path.is_file():
        return
    for raw_line in env_path.read_text(encoding="utf-8", errors="ignore").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export "):].strip()
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip("'\"")
        if key and key not in os.environ:
            os.environ[key] = value


async def prepare_app() -> "Config":
    load_environment_file()
    from config import load_config
    from database import create_tables, init_database

    config = load_config()
    init_database(config)
    await create_tables()
    return config


def prompt_text(prompt: str, *, default: str = "", allow_empty: bool = False) -> str:
    if not is_interactive():
        if default or allow_empty:
            return default
        fail(f"{prompt} is required in non-interactive mode")
    while True:
        suffix = f" [{default}]" if default else ""
        value = input(f"{prompt}{suffix}: ").strip()
        if not value and default:
            return default
        if value or allow_empty:
            return value
        echo("不能为空，请重新输入。", err=True)


def prompt_password_twice() -> str:
    if not is_interactive():
        fail("password input requires an interactive terminal")
    while True:
        first = getpass("密码: ")
        second = getpass("再次输入密码: ")
        if first != second:
            echo("两次密码不一致，请重新输入。", err=True)
            continue
        if len(first) < 4:
            echo("密码至少需要 4 位。", err=True)
            continue
        return first


def confirm(prompt: str, *, default: bool = False, force: bool = False) -> bool:
    if force:
        return True
    if not is_interactive():
        return default
    suffix = " [Y/n] " if default else " [y/N] "
    answer = input(prompt + suffix).strip().lower()
    if not answer:
        return default
    return answer in {"y", "yes"}


def confirm_phrase(prompt: str, phrase: str, *, force: bool = False) -> bool:
    if force:
        return True
    if not is_interactive():
        return False
    echo(prompt)
    answer = input(f"请输入 {phrase!r} 确认: ").strip()
    return answer == phrase


def choose(
    prompt: str,
    options: Sequence[tuple[str, str]],
    *,
    default: str | None = None,
) -> str:
    if not options:
        fail("no options available")
    valid = {key for key, _ in options}
    if default is None:
        default = options[0][0]
    if default not in valid:
        default = options[0][0]
    if not is_interactive():
        return default

    echo(prompt)
    for index, (key, label) in enumerate(options, 1):
        marker = "默认" if key == default else ""
        echo(f"  {index}. {label} ({key}) {marker}".rstrip())
    while True:
        answer = input("选择序号或名称: ").strip()
        if not answer:
            return default
        if answer.isdigit():
            index = int(answer)
            if 1 <= index <= len(options):
                return options[index - 1][0]
        if answer in valid:
            return answer
        echo("无效选择，请重新输入。", err=True)


def print_kv(rows: Iterable[tuple[str, object]]) -> None:
    pairs = [(str(k), "" if v is None else str(v)) for k, v in rows]
    width = max((len(k) for k, _ in pairs), default=0)
    for key, value in pairs:
        echo(f"{key.ljust(width)}  {value}")


def print_table(headers: Sequence[str], rows: Sequence[Sequence[object]]) -> None:
    text_rows = [[str(cell) for cell in row] for row in rows]
    widths = [
        max(len(headers[i]), *(len(row[i]) for row in text_rows)) if text_rows else len(headers[i])
        for i in range(len(headers))
    ]
    echo("  ".join(headers[i].ljust(widths[i]) for i in range(len(headers))))
    echo("  ".join("-" * widths[i] for i in range(len(headers))))
    for row in text_rows:
        echo("  ".join(row[i].ljust(widths[i]) for i in range(len(headers))))


def managed_deployment() -> str:
    """Name of the package manager owning this deployment, or an empty string."""
    key = os.environ.get("SENA_DEPLOYMENT", "").strip().lower()
    return MANAGED_DEPLOYMENTS.get(key, "")


def in_docker() -> bool:
    if Path("/.dockerenv").exists():
        return True
    try:
        cgroup = Path("/proc/1/cgroup").read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return False
    return any(token in cgroup for token in ("docker", "containerd", "kubepods"))


def install_root() -> Path:
    configured = os.environ.get("SENA_INSTALL_ROOT", "").strip()
    if configured:
        return Path(configured)
    parent = SERVER_DIR.parent
    if (parent / "install.sh").is_file():
        return parent
    return Path("/opt/sena-repo")


def installer_path() -> Path:
    root_installer = install_root() / "install.sh"
    if root_installer.is_file():
        return root_installer
    source_installer = SERVER_DIR / "install.sh"
    if source_installer.is_file():
        return source_installer
    fail("install.sh not found")
    raise AssertionError("unreachable")


def uninstaller_path() -> Path:
    root_uninstaller = install_root() / "uninstall.sh"
    if root_uninstaller.is_file():
        return root_uninstaller
    source_uninstaller = SERVER_DIR / "uninstall.sh"
    if source_uninstaller.is_file():
        return source_uninstaller
    fail("uninstall.sh not found")
    raise AssertionError("unreachable")


def run_command(args: Sequence[str], *, env: dict[str, str] | None = None) -> int:
    merged_env = os.environ.copy()
    if env:
        merged_env.update(env)
    proc = subprocess.run(list(args), env=merged_env, check=False)
    return proc.returncode


def read_version_metadata() -> dict[str, str]:
    path = install_root() / ".version"
    if not path.is_file():
        return {}
    result: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        result[key.strip()] = value.strip()
    return result


def remote_source_sha(repo_url: str, repo_ref: str) -> str:
    try:
        proc = subprocess.run(
            ["git", "ls-remote", repo_url, repo_ref],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except OSError:
        return ""
    if proc.returncode != 0:
        return ""
    first = proc.stdout.splitlines()[0].split()[0] if proc.stdout.splitlines() else ""
    return first


def short_sha(value: str) -> str:
    return value[:12] if value else "-"
