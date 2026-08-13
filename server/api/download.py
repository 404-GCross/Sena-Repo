"""File download API - uses FileResponse for reliable async file serving."""

from __future__ import annotations

import asyncio
import hashlib
import hmac
import json
import logging
import re
import secrets
import time
from datetime import datetime
from pathlib import Path
from typing import Literal
from urllib.parse import quote, urlencode

import httpx
from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import FileResponse, RedirectResponse, StreamingResponse
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import joinedload

from api.auth import get_current_user
from config import load_config
from database import get_session
from models.file_source import FileSource
from models.game import Game, GameVersion
from models.root_directory import RootDirectory
from models.user import User
from services.file_source import adapter_from_source

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/download", tags=["download"])

SUPPORTED_MANAGER_ARCHIVE_FORMATS = {
    "7z",
    "zip",
    "rar",
    "tar",
    "tar.gz",
    "tar.bz2",
    "tar.xz",
    "tar.zst",
}

ARCHIVE_SUFFIX_ALIASES = {
    "tgz": "tar.gz",
    "tbz": "tar.bz2",
    "tbz2": "tar.bz2",
    "txz": "tar.xz",
    "tzst": "tar.zst",
}

_SHA256_VALUE_RE = re.compile(
    r"(?:sha[-_]?256)[^0-9a-f]{0,32}([0-9a-f]{64})",
    re.IGNORECASE,
)


class ManagerInstallLinkRequest(BaseModel):
    target: Literal["lunabox", "reinamanager"]


class ManagerInstallLinkResponse(BaseModel):
    target: str
    install_url: str
    expires_at: int
    file_name: str
    archive_format: str
    size: int
    checksum_algo: str
    checksum: str


async def _get_game_and_version(
    game_id: int,
    version_id: int,
    session: AsyncSession,
) -> tuple[Game, GameVersion]:
    result = await session.execute(
        select(Game)
        .options(joinedload(Game.company))
        .where(Game.id == game_id, Game.is_deleted == False)
    )
    game = result.scalar_one_or_none()
    if game is None:
        raise HTTPException(status_code=404, detail="Game not found")

    result = await session.execute(
        select(GameVersion).where(
            GameVersion.id == version_id,
            GameVersion.game_id == game_id,
        )
    )
    version = result.scalar_one_or_none()
    if version is None:
        raise HTTPException(status_code=404, detail="Version not found")
    return game, version


def _signature_secret() -> bytes:
    config = load_config()
    secret_path = Path(config.data_path) / ".manager_install_secret"
    secret_path.parent.mkdir(parents=True, exist_ok=True)
    if secret_path.is_file():
        secret = secret_path.read_text(encoding="utf-8").strip()
        if secret:
            return secret.encode("utf-8")
    secret = secrets.token_hex(32)
    secret_path.write_text(secret, encoding="utf-8")
    try:
        secret_path.chmod(0o600)
    except OSError:
        pass
    return secret.encode("utf-8")


def _signature_payload(game_id: int, version_id: int, expires_at: int) -> bytes:
    return f"{game_id}:{version_id}:{expires_at}".encode("utf-8")


def _sign_download(game_id: int, version_id: int, expires_at: int) -> str:
    return hmac.new(
        _signature_secret(),
        _signature_payload(game_id, version_id, expires_at),
        hashlib.sha256,
    ).hexdigest()


def _verify_download_signature(
    game_id: int,
    version_id: int,
    expires_at: int,
    signature: str,
) -> bool:
    if expires_at <= int(time.time()):
        return False
    expected = _sign_download(game_id, version_id, expires_at)
    return hmac.compare_digest(expected, signature)


def _download_ttl_seconds(file_size: int) -> int:
    gib = 1024 * 1024 * 1024
    if file_size > 20 * gib:
        return 360 * 60
    if file_size > 10 * gib:
        return 240 * 60
    return 120 * 60


def _archive_format(filename: str) -> str:
    lower = filename.strip().lower()
    for suffix in ("tar.gz", "tar.bz2", "tar.xz", "tar.zst"):
        if lower.endswith(f".{suffix}"):
            return suffix
    ext = Path(lower).suffix.removeprefix(".")
    return ARCHIVE_SUFFIX_ALIASES.get(ext, ext)


def _valid_sha256(value: object) -> str | None:
    checksum = str(value or "").strip().lower()
    if len(checksum) == 64 and all(char in "0123456789abcdef" for char in checksum):
        return checksum
    return None


def _normalized_hash_key(key: object) -> str:
    return "".join(char for char in str(key).lower() if char.isalnum())


def _extract_sha256_from_hash_container(value: object) -> str | None:
    direct = _valid_sha256(value)
    if direct:
        return direct

    if isinstance(value, dict):
        for key, nested in value.items():
            if _normalized_hash_key(key).endswith("sha256"):
                checksum = _valid_sha256(nested)
                if checksum:
                    return checksum
        return None

    if isinstance(value, str):
        text = value.strip()
        if text.startswith("{") and text.endswith("}"):
            try:
                parsed = json.loads(text)
            except ValueError:
                parsed = None
            checksum = _extract_sha256_from_hash_container(parsed)
            if checksum:
                return checksum
        match = _SHA256_VALUE_RE.search(text)
        if match:
            return match.group(1).lower()

    return None


def _extract_openlist_sha256(file_info: dict) -> str | None:
    for key, value in file_info.items():
        normalized = _normalized_hash_key(key)
        if normalized.endswith("sha256"):
            checksum = _valid_sha256(value)
            if checksum:
                return checksum
        if normalized in {"hashinfo", "hash", "hashes"}:
            checksum = _extract_sha256_from_hash_container(value)
            if checksum:
                return checksum
    return None


def _sha256_local_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


async def _sha256_url(url: str) -> str:
    digest = hashlib.sha256()
    timeout = httpx.Timeout(None, connect=20.0)
    try:
        async with httpx.AsyncClient(timeout=timeout, follow_redirects=True) as client:
            async with client.stream("GET", url) as response:
                response.raise_for_status()
                async for chunk in response.aiter_bytes(1024 * 1024):
                    digest.update(chunk)
    except httpx.HTTPError as exc:
        raise HTTPException(status_code=502, detail="计算远程文件校验失败，请检查资源连接状态") from exc
    return digest.hexdigest()


async def _calculate_version_sha256(
    version: GameVersion,
    session: AsyncSession,
) -> str:
    if (version.source_type or "local") == "openlist":
        raw_url = await _openlist_download_url(version, session)
        return await _sha256_url(raw_url)

    file_path = Path(version.file_path).resolve()
    if not await _is_allowed_local_file(file_path, session):
        raise HTTPException(status_code=403, detail="File outside games directory")
    if not file_path.is_file():
        raise HTTPException(status_code=404, detail="File not found")
    return await asyncio.to_thread(_sha256_local_file, file_path)


async def _ensure_version_checksum(
    version: GameVersion,
    session: AsyncSession,
) -> str:
    checksum = _cached_version_sha256(version)
    if checksum:
        return checksum

    checksum = await _calculate_version_sha256(version, session)
    await _store_version_sha256(version, session, checksum)
    return checksum


def _cached_version_sha256(version: GameVersion) -> str | None:
    if (version.checksum_algo or "").lower() != "sha256":
        return None
    return _valid_sha256(version.checksum)


async def _store_version_sha256(
    version: GameVersion,
    session: AsyncSession,
    checksum: str,
) -> None:
    version.checksum_algo = "sha256"
    version.checksum = checksum
    version.checksum_updated_at = datetime.utcnow()
    await session.commit()


async def _openlist_adapter(version: GameVersion, session: AsyncSession):
    result = await session.execute(
        select(FileSource).where(FileSource.id == version.source_id)
    )
    source = result.scalar_one_or_none()
    return adapter_from_source(source, "openlist")


async def _openlist_download_url(version: GameVersion, session: AsyncSession) -> str:
    adapter = await _openlist_adapter(version, session)
    return await asyncio.to_thread(
        adapter.download_url,
        version.source_path or version.file_path,
    )


async def _openlist_raw_download_url(version: GameVersion, session: AsyncSession) -> str:
    adapter = await _openlist_adapter(version, session)
    raw_download_url = getattr(adapter, "raw_download_url", None)
    if raw_download_url is None:
        return await _openlist_download_url(version, session)
    return await asyncio.to_thread(
        raw_download_url,
        version.source_path or version.file_path,
    )


async def _openlist_file_info(version: GameVersion, session: AsyncSession) -> dict:
    adapter = await _openlist_adapter(version, session)
    file_info = getattr(adapter, "file_info", None)
    if file_info is None:
        return {}
    return await asyncio.to_thread(file_info, version.source_path or version.file_path)


async def _openlist_metadata_sha256(
    version: GameVersion,
    session: AsyncSession,
) -> str | None:
    return _extract_openlist_sha256(await _openlist_file_info(version, session))


async def _manager_install_checksum(
    version: GameVersion,
    session: AsyncSession,
    target: str,
) -> str:
    checksum = _cached_version_sha256(version)
    if checksum:
        return checksum

    source_type = version.source_type or "local"
    if target == "reinamanager" and source_type == "openlist":
        checksum = await _openlist_metadata_sha256(version, session)
        if checksum:
            await _store_version_sha256(version, session, checksum)
            logger.info(
                "Cached OpenList SHA256 from metadata for manager install vid=%s",
                version.id,
            )
            return checksum

        logger.warning(
            "ReinaManager install link blocked because OpenList SHA256 is missing vid=%s",
            version.id,
        )
        raise HTTPException(
            status_code=409,
            detail="OpenList 资源未提供 SHA256 校验值，ReinaManager 推送不能在生成链接时远程整包计算；请在 OpenList 端启用或补全文件哈希后重新扫描资源。",
        )

    return await _ensure_version_checksum(version, session)


def _download_headers(filename: str) -> dict[str, str]:
    return {
        "Accept-Ranges": "bytes",
        "Content-Disposition": f"attachment; filename*=UTF-8''{quote(filename)}",
    }


def _parse_range_header(range_header: str, file_size: int) -> tuple[int, int]:
    unit, _, value = range_header.partition("=")
    if unit.strip().lower() != "bytes" or "," in value:
        raise HTTPException(
            status_code=416,
            detail="Range not satisfiable",
            headers={"Content-Range": f"bytes */{file_size}"},
        )

    start_text, sep, end_text = value.strip().partition("-")
    if sep != "-":
        raise HTTPException(
            status_code=416,
            detail="Range not satisfiable",
            headers={"Content-Range": f"bytes */{file_size}"},
        )

    try:
        if start_text == "":
            suffix_size = int(end_text)
            if suffix_size <= 0:
                raise ValueError
            start = max(file_size - suffix_size, 0)
            end = file_size - 1
        else:
            start = int(start_text)
            end = int(end_text) if end_text else file_size - 1
    except ValueError as exc:
        raise HTTPException(
            status_code=416,
            detail="Range not satisfiable",
            headers={"Content-Range": f"bytes */{file_size}"},
        ) from exc

    if start < 0 or start >= file_size or end < start:
        raise HTTPException(
            status_code=416,
            detail="Range not satisfiable",
            headers={"Content-Range": f"bytes */{file_size}"},
        )
    return start, min(end, file_size - 1)


async def _iter_file_range(file_path: Path, start: int, end: int):
    with file_path.open("rb") as handle:
        handle.seek(start)
        remaining = end - start + 1
        while remaining > 0:
            chunk = await asyncio.to_thread(handle.read, min(1024 * 1024, remaining))
            if not chunk:
                break
            remaining -= len(chunk)
            yield chunk


def _serve_local_file(request: Request, file_path: Path, filename: str):
    range_header = request.headers.get("range")
    file_size = file_path.stat().st_size
    if range_header:
        start, end = _parse_range_header(range_header, file_size)
        headers = {
            **_download_headers(filename),
            "Content-Range": f"bytes {start}-{end}/{file_size}",
            "Content-Length": str(end - start + 1),
        }
        return StreamingResponse(
            _iter_file_range(file_path, start, end),
            status_code=206,
            media_type="application/octet-stream",
            headers=headers,
        )

    return FileResponse(
        path=str(file_path),
        filename=filename,
        media_type="application/octet-stream",
        headers=_download_headers(filename),
    )


async def _serve_version_download(
    request: Request,
    game: Game,
    version: GameVersion,
    session: AsyncSession,
):
    if (version.source_type or "local") == "openlist":
        raw_url = await _openlist_download_url(version, session)
        return RedirectResponse(raw_url, status_code=302)

    file_path = Path(version.file_path).resolve()
    if not await _is_allowed_local_file(file_path, session):
        raise HTTPException(status_code=403, detail="File outside games directory")

    if not file_path.is_file():
        raise HTTPException(status_code=404, detail="File not found")

    return _serve_local_file(request, file_path, version.filename)


def _build_signed_download_url(
    request: Request,
    game_id: int,
    version_id: int,
    expires_at: int,
) -> str:
    base = str(
        request.url_for(
            "download_signed_game_version",
            game_id=game_id,
            version_id=version_id,
        )
    )
    params = {
        "expires_at": str(expires_at),
        "signature": _sign_download(game_id, version_id, expires_at),
    }
    query = urlencode(params)
    return f"{base}?{query}"


def _primary_lunabox_identity(game: Game) -> tuple[str | None, str | None]:
    if game.vndb_id:
        return "vndb", game.vndb_id
    if game.bangumi_id:
        return "bangumi", game.bangumi_id
    if game.steam_id:
        return "steam", game.steam_id
    return None, None


def _safe_lunabox_install_segment(value: str | None) -> str:
    normalized = re.sub(r'[\\/:*?"<>|\x00]+', "_", str(value or "").strip())
    normalized = re.sub(r"\s+", " ", normalized)
    normalized = normalized.strip(" .")
    return normalized[:120]


def _lunabox_install_subdir(game: Game) -> str | None:
    company_name = game.company.name if game.company else None
    company = _safe_lunabox_install_segment(company_name) or _safe_lunabox_install_segment(
        game.developer
    )
    title = _safe_lunabox_install_segment(game.name)
    if company and title:
        return f"{company}/{title}"
    return title or None


def _set_non_empty(params: dict[str, str], key: str, value: str | None) -> None:
    normalized = (value or "").strip()
    if normalized:
        params[key] = normalized


async def _manager_download_url(
    request: Request,
    game_id: int,
    version_id: int,
    expires_at: int,
) -> tuple[str, int | None]:
    return (
        _build_signed_download_url(
            request,
            game_id,
            version_id,
            expires_at,
        ),
        expires_at,
    )


@router.get("/signed/{game_id}/{version_id}", name="download_signed_game_version")
async def download_signed_game_version(
    game_id: int,
    version_id: int,
    expires_at: int,
    signature: str,
    request: Request,
    session: AsyncSession = Depends(get_session),
):
    """Download a game version through a short-lived signed URL."""
    if not _verify_download_signature(game_id, version_id, expires_at, signature):
        raise HTTPException(status_code=403, detail="下载链接无效或已过期")
    try:
        game, version = await _get_game_and_version(game_id, version_id, session)
        return await _serve_version_download(request, game, version, session)
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Signed download failed gid={game_id} vid={version_id}: {e}")
        raise HTTPException(status_code=500, detail="下载失败，请查看服务端日志")


@router.post("/{game_id}/{version_id}/manager-install-link", response_model=ManagerInstallLinkResponse)
async def create_manager_install_link(
    game_id: int,
    version_id: int,
    body: ManagerInstallLinkRequest,
    request: Request,
    user: User = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
):
    """Create a LunaBox/ReinaManager install protocol URL for a game version."""
    del user
    game, version = await _get_game_and_version(game_id, version_id, session)

    if version.extract_password:
        raise HTTPException(status_code=400, detail="目标管理器暂不支持带解压密码的压缩包，请使用内置下载")

    archive_format = _archive_format(version.filename)
    if archive_format not in SUPPORTED_MANAGER_ARCHIVE_FORMATS:
        raise HTTPException(status_code=400, detail=f"目标管理器暂不支持该压缩格式: {archive_format or '未知'}")

    size = int(version.file_size or 0)
    if size <= 0:
        raise HTTPException(status_code=400, detail="文件大小无效，无法生成管理器安装链接")

    logger.info(
        "Manager install link requested target=%s gid=%s vid=%s source_type=%s checksum_cached=%s",
        body.target,
        game_id,
        version_id,
        version.source_type or "local",
        _cached_version_sha256(version) is not None,
    )
    checksum = await _manager_install_checksum(version, session, body.target)
    expires_at = int(time.time()) + _download_ttl_seconds(size)
    download_url, url_expires_at = await _manager_download_url(
        request,
        game_id,
        version_id,
        expires_at,
    )

    if body.target == "lunabox":
        params = {
            "url": download_url,
            "file_name": version.filename,
            "archive_format": archive_format,
            "size": str(size),
            "checksum_algo": "sha256",
            "checksum": checksum,
            "title": game.name,
            "download_source": "sena-repo",
        }
        install_subdir = _lunabox_install_subdir(game)
        if install_subdir:
            params["install_subdir"] = install_subdir
        if url_expires_at is not None:
            params["expires_at"] = str(url_expires_at)
        meta_source, meta_id = _primary_lunabox_identity(game)
        if meta_source and meta_id:
            params["source"] = meta_source
            params["meta_id"] = meta_id
        install_url = "lunabox://install?" + urlencode(params)
    else:
        if (version.source_type or "local") == "openlist":
            download_url = await _openlist_raw_download_url(version, session)
            url_expires_at = None
        params = {
            "v": "1",
            "provider": "sena-repo",
            "resource_id": f"game-{game.id}-version-{version.id}",
            "url": download_url,
            "file_name": version.filename,
            "archive_format": archive_format,
            "size": str(size),
            "checksum_algo": "sha256",
            "checksum": checksum,
            "title": game.name,
        }
        # ReinaManager does its own preflight expiry check; rely on Sena's
        # signed URL validation to avoid rejecting valid tasks on clock skew.
        _set_non_empty(params, "bgm_id", game.bangumi_id)
        _set_non_empty(params, "vndb_id", game.vndb_id)
        _set_non_empty(params, "hikarinagi_id", getattr(game, "hikarinagi_id", None))
        install_url = "reinamanager://install?" + urlencode(params)

    return ManagerInstallLinkResponse(
        target=body.target,
        install_url=install_url,
        expires_at=url_expires_at or 0,
        file_name=version.filename,
        archive_format=archive_format,
        size=size,
        checksum_algo="sha256",
        checksum=checksum,
    )


@router.get("/{game_id}/{version_id}")
async def download_game_version(
    game_id: int,
    version_id: int,
    request: Request,
    user: User = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
):
    """Download a specific game version archive file."""
    try:
        game, version = await _get_game_and_version(game_id, version_id, session)
        return await _serve_version_download(request, game, version, session)
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Download failed gid={game_id} vid={version_id}: {e}")
        raise HTTPException(status_code=500, detail="下载失败，请查看服务端日志")


async def _is_allowed_local_file(file_path: Path, session: AsyncSession) -> bool:
    """Allow local downloads only from configured local roots or legacy games_path."""
    roots: list[Path] = []
    result = await session.execute(
        select(RootDirectory).where(RootDirectory.source_type == "local")
    )
    for root in result.scalars().all():
        root_path = root.source_path or root.path
        if root_path:
            roots.append(Path(root_path).resolve())

    config = load_config()
    roots.append(Path(config.games_path).resolve())

    for root in roots:
        try:
            file_path.relative_to(root)
            return True
        except ValueError:
            continue
    return False
