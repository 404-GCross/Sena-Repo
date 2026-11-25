"""Unified file source adapters for local files and OpenList."""

from __future__ import annotations

import hashlib
import posixpath
import stat
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol
from urllib.parse import quote, urlencode, urljoin

import httpx
from fastapi import HTTPException

from models.file_source import FileSource
from utils.secrets import decrypt_secret
from services.task_stop import checkpoint


@dataclass(frozen=True)
class FileEntry:
    name: str
    path: str
    is_dir: bool
    size: int = 0
    modified: str | None = None


class FileSourceAdapter(Protocol):
    def list(self, path: str) -> list[FileEntry]:
        ...

    def exists(self, path: str) -> bool:
        ...

    def download_url(self, path: str) -> str:
        ...


def normalize_remote_path(path: str) -> str:
    cleaned = (path or "").replace("\\", "/").strip()
    if not cleaned:
        return "/"
    if not cleaned.startswith("/"):
        cleaned = "/" + cleaned
    normalized = posixpath.normpath(cleaned)
    if normalized == ".":
        normalized = "/"
    if ".." in normalized.split("/"):
        raise HTTPException(status_code=400, detail="Invalid source path")
    return normalized


def canonical_source_path(source_type: str, source_id: int | None, path: str) -> str:
    if source_type == "openlist":
        return f"openlist://{source_id or 0}{normalize_remote_path(path)}"
    return path


def normalize_base_url(base_url: str | None) -> str:
    cleaned = (base_url or "").strip().rstrip("/")
    if not cleaned:
        return ""
    if "://" not in cleaned:
        cleaned = "http://" + cleaned
    return cleaned


class SourceUnavailable(RuntimeError):
    """An incomplete inventory must never be reconciled as an empty source."""


def local_entries(path: Path):
    try:
        for entry in sorted(path.iterdir()):
            checkpoint()
            yield entry, entry.stat()
    except OSError as exc:
        raise SourceUnavailable("本地目录不可完整读取，请检查挂载和权限") from exc


def local_files(path: Path, ignored: set[str] | None = None):
    pending = [path]
    while pending:
        for entry, info in local_entries(pending.pop()):
            if ignored and str(entry) in ignored:
                continue
            if stat.S_ISREG(info.st_mode):
                yield entry, info
            elif stat.S_ISDIR(info.st_mode) and not entry.is_symlink():
                pending.append(entry)


class LocalFileSource:
    def list(self, path: str) -> list[FileEntry]:
        root = Path(path)
        entries: list[FileEntry] = []
        for entry, info in local_entries(root):
            entries.append(
                FileEntry(
                    name=entry.name,
                    path=str(entry),
                    is_dir=stat.S_ISDIR(info.st_mode),
                    size=info.st_size if stat.S_ISREG(info.st_mode) else 0,
                    modified=str(info.st_mtime),
                )
            )
        return entries

    def exists(self, path: str) -> bool:
        return Path(path).exists()

    def download_url(self, path: str) -> str:
        raise RuntimeError("Local files are served with FileResponse")


class OpenListFileSource:
    _STATIC_HASH_SALT = "https://github.com/alist-org/alist"

    def __init__(self, source: FileSource):
        self.source = source
        self.base_url = normalize_base_url(source.base_url)
        self.username = source.username or ""
        self.password = decrypt_secret(source.password)
        self._token: str | None = None

    @property
    def _is_guest(self) -> bool:
        """True when no credentials are configured — use OpenList guest access."""
        return not self.username

    def _url(self, endpoint: str) -> str:
        return urljoin(self.base_url + "/", endpoint.lstrip("/"))

    def _client(self) -> httpx.Client:
        return httpx.Client(timeout=httpx.Timeout(20.0, connect=8.0), follow_redirects=True)

    def _login(self) -> str:
        if not self.base_url:
            raise HTTPException(status_code=400, detail="OpenList base URL is empty")
        password_hash = hashlib.sha256(f"{self.password}-{self._STATIC_HASH_SALT}".encode("utf-8")).hexdigest()
        try:
            with self._client() as client:
                resp = client.post(
                    self._url("/api/auth/login/hash"),
                    json={"username": self.username, "password": password_hash, "otp_code": ""},
                )
                data = self._parse_login_response(resp)
                if data is None:
                    resp = client.post(
                        self._url("/api/auth/login"),
                        json={"username": self.username, "password": self.password, "otp_code": ""},
                    )
                    data = self._parse_login_response(resp, strict=True)
        except httpx.HTTPError as exc:
            raise HTTPException(status_code=502, detail=f"OpenList login request failed: {exc}") from exc
        token = ((data.get("data") or {}).get("token") or "").strip()
        if not token:
            raise HTTPException(status_code=502, detail="OpenList did not return a token")
        self._token = token
        return token

    def _parse_login_response(self, resp: httpx.Response, strict: bool = False) -> dict | None:
        if resp.status_code >= 400:
            if strict:
                raise HTTPException(status_code=502, detail="OpenList login failed")
            return None
        try:
            data = resp.json()
        except ValueError as exc:
            raise HTTPException(status_code=502, detail="OpenList login returned invalid JSON") from exc
        if data.get("code") not in (None, 200):
            if strict:
                raise HTTPException(status_code=502, detail=data.get("message") or "OpenList login failed")
            return None
        return data

    def _headers(self) -> dict[str, str]:
        # Guest mode: send no Authorization header so OpenList falls back to its
        # built-in guest user (empty token → guest in OpenList middleware).
        if self._is_guest:
            return {}
        return {"Authorization": self._token or self._login()}

    def _post(self, endpoint: str, body: dict, retry: bool = True) -> dict:
        try:
            with self._client() as client:
                resp = client.post(self._url(endpoint), json=body, headers=self._headers())
        except httpx.HTTPError as exc:
            raise HTTPException(status_code=502, detail=f"OpenList request failed: {exc}") from exc
        # Only retry auth for authenticated sessions, not guest (no token to refresh).
        if resp.status_code in {401, 403} and retry and not self._is_guest:
            self._token = None
            return self._post(endpoint, body, retry=False)
        if resp.status_code >= 400:
            raise HTTPException(status_code=502, detail=f"OpenList request failed: {resp.status_code}")
        try:
            data = resp.json()
        except ValueError as exc:
            raise HTTPException(status_code=502, detail="OpenList returned invalid JSON") from exc
        if data.get("code") in (401, 403) and retry and not self._is_guest:
            self._token = None
            return self._post(endpoint, body, retry=False)
        if data.get("code") not in (None, 200):
            raise HTTPException(status_code=502, detail=data.get("message") or "OpenList request failed")
        return data.get("data") or {}

    def list(self, path: str) -> list[FileEntry]:
        remote_path = normalize_remote_path(path)
        # Restart from page one: combining pages across attempts can lose entries.
        for attempt in range(2):
            try:
                return self._list_snapshot(remote_path, refresh=bool(attempt))
            except (SourceUnavailable, HTTPException, ValueError, TypeError) as exc:
                if attempt:
                    raise SourceUnavailable(
                        "网盘目录枚举不完整，请检查来源后重试"
                    ) from exc

    def _list_snapshot(self, remote_path: str, *, refresh: bool) -> list[FileEntry]:
        entries: list[FileEntry] = []
        seen = set()
        page = 1
        per_page = 100
        total: int | None = None
        while True:
            checkpoint()
            data = self._post(
                "/api/fs/list",
                {"path": remote_path, "password": "", "page": page, "per_page": per_page, "refresh": refresh and page == 1},
            )
            if not isinstance(data, dict) or "content" not in data:
                raise SourceUnavailable("网盘目录响应缺少条目列表")
            raw_total = data.get("total")
            if (
                type(raw_total) is not int
                or raw_total < 0
                or (total is not None and total != raw_total)
            ):
                raise SourceUnavailable("网盘目录总数缺失或发生变化")
            total = raw_total
            content = data["content"]
            if content is None and total == 0:
                content = []
            if not isinstance(content, list):
                raise SourceUnavailable('网盘目录列表无效')
            for item in content:
                name = item.get("name") if isinstance(item, dict) else None
                if (
                    not isinstance(name, str)
                    or not name
                    or name in {".", ".."}
                    or "/" in name
                    or "\\" in name
                    or type(item.get("is_dir")) is not bool
                ):
                    raise SourceUnavailable('网盘目录条目无效')
                child_path = normalize_remote_path(posixpath.join(remote_path, name))
                if child_path in seen:
                    raise SourceUnavailable("网盘分页存在重复条目")
                seen.add(child_path)
                entries.append(
                    FileEntry(
                        name=name,
                        path=child_path,
                        is_dir=bool(item.get("is_dir")),
                        size=int(item.get("size") or 0),
                        modified=item.get("modified"),
                    )
                )
            if len(entries) == total:
                break
            if not content or len(entries) > total:
                raise SourceUnavailable('网盘目录枚举与总数不符')
            page += 1
        entries.sort(key=lambda e: (not e.is_dir, e.name.lower()))
        return entries

    def exists(self, path: str) -> bool:
        remote_path = normalize_remote_path(path)
        try:
            self._post(
                "/api/fs/list",
                {"path": remote_path, "password": "", "page": 1, "per_page": 1, "refresh": False},
            )
            return True
        except HTTPException:
            try:
                self._post("/api/fs/get", {"path": remote_path, "password": ""})
                return True
            except HTTPException:
                return False

    def _file_info(self, path: str) -> dict:
        remote_path = normalize_remote_path(path)
        data = self._post("/api/fs/get", {"path": remote_path, "password": ""})
        if data.get("is_dir"):
            raise HTTPException(status_code=400, detail="OpenList path is a directory")
        return data

    def file_info(self, path: str) -> dict:
        return self._file_info(path)

    def _download_url(self, path: str, prefix: str) -> str:
        remote_path = normalize_remote_path(path)
        data = self._file_info(remote_path)
        sign = (data.get("sign") or "").strip()
        query = f"?{urlencode({'sign': sign})}" if sign else ""
        return self._url(prefix + quote(remote_path, safe="/") + query)

    def download_url(self, path: str) -> str:
        return self._download_url(path, "d")

    def proxy_download_url(self, path: str) -> str:
        return self._download_url(path, "p")

    def raw_download_url(self, path: str) -> str:
        raw_url = (self._file_info(path).get("raw_url") or "").strip()
        return raw_url or self.download_url(path)


def adapter_from_source(source: FileSource | None, source_type: str = "local") -> FileSourceAdapter:
    if source_type == "openlist":
        if source is None:
            raise HTTPException(status_code=404, detail="OpenList source not found")
        return OpenListFileSource(source)
    return LocalFileSource()
