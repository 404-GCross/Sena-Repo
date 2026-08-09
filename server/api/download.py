"""File download API - uses FileResponse for reliable async file serving."""

from __future__ import annotations

import asyncio
import hashlib
import hmac
import logging
import secrets
import time
from datetime import datetime
from pathlib import Path
from typing import Literal
from urllib.parse import urlencode

import httpx
from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import FileResponse, RedirectResponse
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

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
        select(Game).where(Game.id == game_id, Game.is_deleted == False)
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
        raise HTTPException(status_code=502, detail=f"计算远程文件校验失败: {exc}") from exc
    return digest.hexdigest()


async def _calculate_version_sha256(
    version: GameVersion,
    session: AsyncSession,
) -> str:
    if (version.source_type or "local") == "openlist":
        result = await session.execute(select(FileSource).where(FileSource.id == version.source_id))
        source = result.scalar_one_or_none()
        adapter = adapter_from_source(source, "openlist")
        raw_url = await asyncio.to_thread(adapter.download_url, version.source_path or version.file_path)
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
    checksum = (version.checksum or "").strip().lower()
    if (
        (version.checksum_algo or "").lower() == "sha256"
        and len(checksum) == 64
        and all(char in "0123456789abcdef" for char in checksum)
    ):
        return checksum

    checksum = await _calculate_version_sha256(version, session)
    version.checksum_algo = "sha256"
    version.checksum = checksum
    version.checksum_updated_at = datetime.utcnow()
    await session.commit()
    return checksum


async def _serve_version_download(
    game: Game,
    version: GameVersion,
    session: AsyncSession,
):
    if (version.source_type or "local") == "openlist":
        result = await session.execute(select(FileSource).where(FileSource.id == version.source_id))
        source = result.scalar_one_or_none()
        adapter = adapter_from_source(source, "openlist")
        raw_url = await asyncio.to_thread(adapter.download_url, version.source_path or version.file_path)
        return RedirectResponse(raw_url, status_code=302)

    file_path = Path(version.file_path).resolve()
    if not await _is_allowed_local_file(file_path, session):
        raise HTTPException(status_code=403, detail="File outside games directory")

    if not file_path.is_file():
        raise HTTPException(status_code=404, detail="File not found")

    return FileResponse(
        path=str(file_path),
        filename=version.filename,
        media_type="application/octet-stream",
    )


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
    query = urlencode(
        {
            "expires_at": str(expires_at),
            "signature": _sign_download(game_id, version_id, expires_at),
        }
    )
    return f"{base}?{query}"


def _primary_lunabox_identity(game: Game) -> tuple[str | None, str | None]:
    if game.vndb_id:
        return "vndb", game.vndb_id
    if game.bangumi_id:
        return "bangumi", game.bangumi_id
    if game.steam_id:
        return "steam", game.steam_id
    return None, None


@router.get("/signed/{game_id}/{version_id}", name="download_signed_game_version")
async def download_signed_game_version(
    game_id: int,
    version_id: int,
    expires_at: int,
    signature: str,
    session: AsyncSession = Depends(get_session),
):
    """Download a game version through a short-lived signed URL."""
    if not _verify_download_signature(game_id, version_id, expires_at, signature):
        raise HTTPException(status_code=403, detail="下载链接无效或已过期")
    try:
        game, version = await _get_game_and_version(game_id, version_id, session)
        return await _serve_version_download(game, version, session)
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
    if body.target == "reinamanager" and not (game.bangumi_id or "").strip():
        raise HTTPException(status_code=400, detail="ReinaManager 推送需要 Bangumi ID，请先补全该条目的 Bangumi ID")

    archive_format = _archive_format(version.filename)
    if archive_format not in SUPPORTED_MANAGER_ARCHIVE_FORMATS:
        raise HTTPException(status_code=400, detail=f"目标管理器暂不支持该压缩格式: {archive_format or '未知'}")

    size = int(version.file_size or 0)
    if size <= 0:
        raise HTTPException(status_code=400, detail="文件大小无效，无法生成管理器安装链接")

    checksum = await _ensure_version_checksum(version, session)
    expires_at = int(time.time()) + _download_ttl_seconds(size)
    signed_url = _build_signed_download_url(request, game_id, version_id, expires_at)

    if body.target == "lunabox":
        params = {
            "url": signed_url,
            "file_name": version.filename,
            "archive_format": archive_format,
            "size": str(size),
            "expires_at": str(expires_at),
            "checksum_algo": "sha256",
            "checksum": checksum,
            "title": game.name,
            "download_source": "sena-repo",
        }
        meta_source, meta_id = _primary_lunabox_identity(game)
        if meta_source and meta_id:
            params["source"] = meta_source
            params["meta_id"] = meta_id
        install_url = "lunabox://install?" + urlencode(params)
    else:
        params = {
            "v": "1",
            "provider": "sena-repo",
            "resource_id": f"game-{game.id}-version-{version.id}",
            "url": signed_url,
            "file_name": version.filename,
            "archive_format": archive_format,
            "size": str(size),
            "checksum_algo": "sha256",
            "checksum": checksum,
            "expires_at": str(expires_at),
            "bgm_id": game.bangumi_id or "",
            "title": game.name,
        }
        if game.vndb_id:
            params["vndb_id"] = game.vndb_id
        install_url = "reinamanager://install?" + urlencode(params)

    return ManagerInstallLinkResponse(
        target=body.target,
        install_url=install_url,
        expires_at=expires_at,
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
    user: User = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
):
    """Download a specific game version archive file."""
    try:
        game, version = await _get_game_and_version(game_id, version_id, session)
        return await _serve_version_download(game, version, session)
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
