"""Unified file source adapters for local files and OpenList."""

from __future__ import annotations

import hashlib
import posixpath
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol
from urllib.parse import urljoin

import httpx
from fastapi import HTTPException

from models.file_source import FileSource


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


class LocalFileSource:
    def list(self, path: str) -> list[FileEntry]:
        root = Path(path)
        if not root.is_dir():
            return []
        entries: list[FileEntry] = []
        for entry in sorted(root.iterdir(), key=lambda p: p.name.lower()):
            try:
                stat = entry.stat()
            except OSError:
                continue
            entries.append(
                FileEntry(
                    name=entry.name,
                    path=str(entry),
                    is_dir=entry.is_dir(),
                    size=stat.st_size if entry.is_file() else 0,
                    modified=str(stat.st_mtime),
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
        self.password = source.password or ""
        self._token: str | None = None

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
        return {"Authorization": self._token or self._login()}

    def _post(self, endpoint: str, body: dict, retry: bool = True) -> dict:
        try:
            with self._client() as client:
                resp = client.post(self._url(endpoint), json=body, headers=self._headers())
        except httpx.HTTPError as exc:
            raise HTTPException(status_code=502, detail=f"OpenList request failed: {exc}") from exc
        if resp.status_code in {401, 403} and retry:
            self._token = None
            return self._post(endpoint, body, retry=False)
        if resp.status_code >= 400:
            raise HTTPException(status_code=502, detail=f"OpenList request failed: {resp.status_code}")
        try:
            data = resp.json()
        except ValueError as exc:
            raise HTTPException(status_code=502, detail="OpenList returned invalid JSON") from exc
        if data.get("code") in (401, 403) and retry:
            self._token = None
            return self._post(endpoint, body, retry=False)
        if data.get("code") not in (None, 200):
            raise HTTPException(status_code=502, detail=data.get("message") or "OpenList request failed")
        return data.get("data") or {}

    def list(self, path: str) -> list[FileEntry]:
        remote_path = normalize_remote_path(path)
        entries: list[FileEntry] = []
        page = 1
        per_page = 100
        total: int | None = None
        while True:
            data = self._post(
                "/api/fs/list",
                {"path": remote_path, "password": "", "page": page, "per_page": per_page, "refresh": False},
            )
            content = data.get("content") or []
            if total is None:
                raw_total = data.get("total")
                total = int(raw_total) if raw_total is not None else None
            for item in content:
                name = item.get("name") or ""
                if not name:
                    continue
                child_path = normalize_remote_path(posixpath.join(remote_path, name))
                entries.append(
                    FileEntry(
                        name=name,
                        path=child_path,
                        is_dir=bool(item.get("is_dir")),
                        size=int(item.get("size") or 0),
                        modified=item.get("modified"),
                    )
                )
            if not content or len(content) < per_page or (total is not None and len(entries) >= total):
                break
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

    def download_url(self, path: str) -> str:
        data = self._post("/api/fs/get", {"path": normalize_remote_path(path), "password": ""})
        raw_url = (data.get("raw_url") or "").strip()
        if not raw_url:
            raise HTTPException(status_code=502, detail="OpenList did not return a download URL")
        return raw_url


def adapter_from_source(source: FileSource | None, source_type: str = "local") -> FileSourceAdapter:
    if source_type == "openlist":
        if source is None:
            raise HTTPException(status_code=404, detail="OpenList source not found")
        return OpenListFileSource(source)
    return LocalFileSource()
