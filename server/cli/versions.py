"""Display project versions separately from source revisions."""

from __future__ import annotations

import os
import re
import subprocess
import urllib.request
from pathlib import Path

from cli.common import SERVER_DIR, install_root, mirror_candidates

_VERSION = re.compile(
    r"v?(\d+\.\d+\.\d+(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?"
    r"(?:\+[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?)"
)
_SHA = re.compile(r"[0-9a-f]{40}")


def project_version(value: str) -> str:
    value = value.strip()
    match = _VERSION.fullmatch(value) if len(value) <= 128 else None
    return match.group(1) if match else ""


def _read_version(path: Path) -> str:
    try:
        with path.open(encoding="utf-8") as handle:
            return project_version(handle.read(256))
    except (OSError, UnicodeError):
        return ""


def _cached_version(sha: str) -> str:
    if not _SHA.fullmatch(sha):
        return ""
    cache = install_root() / "repo"
    if not (cache / ".git").exists():
        return ""
    try:
        result = subprocess.run(
            ["git", "-C", str(cache), "show", f"{sha}:VERSION"],
            check=False,
            capture_output=True,
            text=True,
            timeout=5,
        )
        return project_version(result.stdout) if result.returncode == 0 else ""
    except (OSError, UnicodeError, subprocess.TimeoutExpired):
        return ""


def _version_url(repo_url: str, sha: str) -> str:
    prefix, marker, repo = repo_url.partition("https://github.com/")
    if not marker or (
        prefix
        and not (prefix.startswith(("http://", "https://")) and prefix.endswith("/"))
    ):
        return ""
    repo = repo.rstrip("/").removesuffix(".git")
    if not re.fullmatch(r"[\w.-]+/[\w.-]+", repo):
        return ""
    return f"{prefix}https://raw.githubusercontent.com/{repo}/{sha}/VERSION"


def remote_project_version(repo_url: str, sha: str, ref: str = "") -> str:
    # A release tag is the published version, even if its source VERSION differs.
    if ref.startswith("v") and (version := project_version(ref)):
        return version
    if not _SHA.fullmatch(sha):
        return ""
    cached = _cached_version(sha)
    if cached:
        return cached
    for source in dict.fromkeys([repo_url, *mirror_candidates(repo_url)]):
        url = _version_url(source, sha)
        if not url:
            continue
        try:
            request = urllib.request.Request(
                url, headers={"User-Agent": "Sena-Repo/senacli", "Accept": "text/plain"}
            )
            with urllib.request.urlopen(request, timeout=5) as response:
                version = project_version(response.read(256).decode("utf-8"))
            if version:
                return version
        except (OSError, ValueError):
            continue
    return ""


def installed_project_version(
    metadata: dict[str, str], *, allow_remote: bool = False
) -> str:
    for candidate in (
        metadata.get("SOURCE_VERSION", ""),
        os.environ.get("SENA_VERSION", ""),
        metadata.get("SOURCE_REF", ""),
    ):
        if version := project_version(candidate):
            return version
    # This file is staged with the installed tree, not the mutable source cache.
    if version := _read_version(SERVER_DIR / "VERSION"):
        return version
    sha = metadata.get("SOURCE_SHA", "")
    if version := _cached_version(sha):
        return version
    if allow_remote:
        return remote_project_version(metadata.get("SOURCE_URL", ""), sha)
    return ""


def version_label(version: str, ref: str) -> str:
    if not version:
        return "未知（无法读取项目版本，仍按提交号检查更新）"
    if project_version(ref):
        kind = "测试版" if "-" in version.split("+", 1)[0] else "正式版"
    else:
        kind = "开发版"
    return f"v{version}（{kind}）"
