from __future__ import annotations

import asyncio
import os
import posixpath
import stat
import subprocess
import threading
import zipfile
from pathlib import Path

from services.file_source import adapter_from_source, canonical_source_path
from utils.file_utils import is_archive


def relative_path(value: str, allow_empty=False) -> str:
    value = value.replace("\\", "/")
    if not value and allow_empty:
        return ""
    if (
        not value
        or value.startswith("/")
        or ":" in value
        or "\x00" in value
        or any(p in {"..", ".", ""} for p in value.split("/"))
    ):
        raise ValueError("无效相对路径")
    return value


def inventory(root, source, ignored: set[str], max_entries=20000):
    base = root.source_path or root.path if hasattr(root, "source_path") else root.path
    local = (root.source_type or "local") == "local"
    adapter = adapter_from_source(source, root.source_type or "local")
    root_path = Path(base).resolve() if local else None
    pending, visited, files = [base], set(), []
    seen = 0
    while pending:
        current = pending.pop()
        if current in visited:
            continue
        visited.add(current)
        for item in adapter.list(current):
            seen += 1
            if seen > max_entries:
                raise ValueError("智能目录清单超过上限，改用常规扫描")
            canonical = canonical_source_path(
                root.source_type or "local", root.source_id, item.path
            )
            if any(
                canonical == p or canonical.startswith(p.rstrip("/") + "/")
                for p in ignored
            ):
                continue
            if local:
                path = Path(item.path)
                if path.is_symlink() or not path.resolve().is_relative_to(root_path):
                    continue
                rel = str(path.relative_to(Path(base))).replace(os.sep, "/")
            else:
                rel = posixpath.relpath(item.path, base)
                relative_path(rel)
            if item.is_dir:
                pending.append(item.path)
            elif is_archive(item.name) or item.name.lower().endswith(
                (".exe", ".txt", ".md")
            ):
                files.append(
                    {
                        "id": len(files),
                        "path": item.path,
                        "relative": rel,
                        "size": item.size,
                        "modified": item.modified,
                        "archive": is_archive(item.name),
                    }
                )
    return files


def archive_evidence(path: Path) -> dict:
    from api.steam_patch import _list_zip_entries, _parse_7z_slt, _seven_zip_executable

    if zipfile.is_zipfile(path):
        with zipfile.ZipFile(path) as archive:
            if len(archive.infolist()) > 2500:
                raise ValueError("压缩包条目过多")
            for entry in archive.infolist():
                if stat.S_IFMT(entry.external_attr >> 16) not in (
                    0,
                    stat.S_IFREG,
                    stat.S_IFDIR,
                ):
                    raise ValueError("压缩包包含特殊文件")
                relative_path(entry.filename.rstrip("/"))
        tree, risks = _list_zip_entries(path)
    else:
        exe = _seven_zip_executable()
        if not exe:
            raise ValueError("服务端未安装压缩包目录工具")
        listing = bounded_tool(
            [exe, "l", "-slt", "-p-", "--", str(path)], 4 * 1024 * 1024
        ).decode("utf-8", "replace")
        if any(
            marker in listing
            for marker in (
                "Symbolic Link =",
                "Hard Link =",
                "Reparse =",
                "Mode = l",
                "Mode = b",
                "Mode = c",
            )
        ):
            raise ValueError("压缩包包含链接或特殊文件")
        tree, risks = _parse_7z_slt(listing, path)
    if len(tree) >= 2500 or any(r.get("level") == "error" for r in risks):
        raise ValueError("压缩包清单不完整或不安全")
    text = []
    # Read bounded text only; never extract an archive into the filesystem.
    if zipfile.is_zipfile(path):
        with zipfile.ZipFile(path) as archive:
            for item in archive.infolist():
                name = item.filename.lower()
                if (
                    not name.endswith((".txt", ".md"))
                    or item.file_size > 32768
                    or len(text) >= 4
                ):
                    continue
                relative_path(item.filename.rstrip("/"))
                if stat.S_ISLNK(item.external_attr >> 16):
                    continue
                with archive.open(item) as handle:
                    raw = handle.read(32769)
                if len(raw) > 32768:
                    continue
                for encoding in ("utf-8-sig", "gb18030", "shift_jis"):
                    try:
                        body = raw.decode(encoding)
                        break
                    except UnicodeError:
                        body = ""
                if body:
                    text.append({"path": item.filename, "text": body})
    else:
        from api.steam_patch import _seven_zip_executable

        exe = _seven_zip_executable()
        if exe:
            for entry in tree:
                name = entry["path"]
                if (
                    entry["type"] != "file"
                    or not name.lower().endswith((".txt", ".md"))
                    or entry.get("size", 0) > 32768
                    or len(text) >= 4
                ):
                    continue
                relative_path(name)
                if name.startswith(("@", "-")):
                    continue
                raw = bounded_tool(
                    [exe, "x", "-so", "-p-", "-spd", "--", str(path), name], 32768
                )
                for encoding in ("utf-8-sig", "gb18030", "shift_jis"):
                    try:
                        body = raw.decode(encoding)
                        break
                    except UnicodeError:
                        body = ""
                if body:
                    text.append({"path": name, "text": body})
    return {"documents": text, "tree": tree[:1500], "complete": len(tree) <= 1500}


def bounded_tool(command, limit):
    process = subprocess.Popen(
        command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL
    )
    timer = threading.Timer(30, process.kill)
    timer.start()
    try:
        data = process.stdout.read(limit + 1)
        if len(data) > limit:
            raise ValueError("工具输出超过限制")
        process.wait(timeout=2)
        if process.returncode:
            raise ValueError("压缩包工具无法读取")
        return data
    finally:
        timer.cancel()
        if process.poll() is None:
            process.kill()
        process.wait()
        process.stdout.close()


async def inspect_file(root, source, item, settings):
    if (root.source_type or "local") == "local":
        path = Path(item["path"])
        base = Path(getattr(root, "source_path", None) or root.path).resolve()
        if path.is_symlink() or not path.resolve().is_relative_to(base):
            raise ValueError("文件超出扫描范围")
        if not item["archive"]:
            if (
                path.suffix.lower() not in {".txt", ".md"}
                or path.stat().st_size > 32768
            ):
                return {"error": "Only small text documents can be read"}
            return {
                "text": await asyncio.to_thread(
                    path.read_text, encoding="utf-8", errors="replace"
                )
            }
        return await asyncio.to_thread(archive_evidence, path)
    import tempfile
    import httpx

    limit = settings.remote_archive_mb * 1024 * 1024
    if not item["archive"] or not limit or item["size"] > limit:
        return {"error": "Remote archive exceeds the configured inspection budget"}
    adapter = adapter_from_source(source, "openlist")
    url = await asyncio.to_thread(adapter.download_url, item["path"])
    with tempfile.TemporaryDirectory(prefix="sena-agent-") as tmp:
        path = Path(tmp) / Path(item["path"]).name
        async with httpx.AsyncClient(timeout=30, follow_redirects=True) as client:
            async with client.stream("GET", url) as response:
                response.raise_for_status()
                size = 0
                with path.open("wb") as handle:
                    async for chunk in response.aiter_bytes():
                        size += len(chunk)
                        if size > limit:
                            raise ValueError("远程压缩包下载超过限制")
                        handle.write(chunk)
        return await asyncio.to_thread(archive_evidence, path)
