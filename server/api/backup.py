"""Server backup management API.

Every endpoint requires an administrator; the archives carry account
credentials, so access stays limited to the management role."""

from __future__ import annotations

import asyncio
import logging
import secrets
import zipfile
from datetime import datetime, timezone
from pathlib import Path

from fastapi import APIRouter, Depends, File, Form, HTTPException, UploadFile
from fastapi.responses import FileResponse
from pydantic import BaseModel

from api.auth import require_admin
from cli import backup as backup_cli
from cli.common import CliError
from config import load_config
from models.user import User
from utils.log_redaction import redact_exception
from utils import backup_limits

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/backup", tags=["backup"])

BACKUP_SUFFIXES = {".zip", ".json"}
BACKUP_PREFIXES = ("sena-backup-", "uploaded-", "auto-sena-backup-")


def _backup_source(name: str) -> str:
    if name.startswith("auto-sena-backup-"):
        return "auto"
    if name.startswith("uploaded-"):
        return "upload"
    return "manual"


def _backups_root() -> Path:
    return backup_cli.backups_root(load_config())


def _is_backup_file(path: Path) -> bool:
    """Only archives this API creates count as backups; the directory also holds
    docker inspect dumps and pre-restore safety copies."""
    return path.name.startswith(BACKUP_PREFIXES) and path.suffix.lower() in BACKUP_SUFFIXES


def _resolve(name: str) -> Path:
    """Resolve a backup file name inside the backups directory."""
    root = _backups_root()
    candidate = (root / name).resolve()
    try:
        candidate.relative_to(root.resolve())
    except ValueError as exc:
        raise HTTPException(status_code=400, detail="非法的备份文件名") from exc
    if not candidate.is_file() or not _is_backup_file(candidate):
        raise HTTPException(status_code=404, detail="备份文件不存在")
    return candidate


def _entry(path: Path, root: Path) -> dict:
    stat = path.stat()
    has_media = False
    if path.suffix.lower() == ".zip" and zipfile.is_zipfile(path):
        try:
            with zipfile.ZipFile(path) as archive:
                has_media = any(
                    name.startswith("media/") for name in archive.namelist()
                )
        except (OSError, zipfile.BadZipFile):
            has_media = False
    return {
        "name": path.relative_to(root).as_posix(),
        "source": _backup_source(path.name),
        "size": stat.st_size,
        "modified_at": datetime.fromtimestamp(
            stat.st_mtime, tz=timezone.utc
        ).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "has_media": has_media,
    }


@router.get("/list")
async def list_backups(user: User = Depends(require_admin)):
    """List backup archives stored under the data directory."""
    root = _backups_root()
    entries = []
    for path in sorted(root.rglob("*")):
        if not path.is_file() or not _is_backup_file(path):
            continue
        entries.append(_entry(path, root))
    entries.sort(key=lambda item: item["modified_at"], reverse=True)
    return {"backups": entries, "directory": str(root)}


class ExportRequest(BaseModel):
    scope: str = backup_cli.SCOPE_ALL  # all | library | patch
    include_media: bool = True


@router.post("/export")
async def export_backup(body: ExportRequest, user: User = Depends(require_admin)):
    """Create a backup archive on the server; the client downloads it afterwards."""
    config = load_config()
    scope = (body.scope or backup_cli.SCOPE_ALL).strip().lower()
    if scope not in backup_cli.EXPORT_SCOPES:
        raise HTTPException(status_code=400, detail="未知的备份范围")
    # Media only exists in the library part of a backup.
    include_media = body.include_media and scope != backup_cli.SCOPE_PATCH
    suffix = ".zip" if include_media else ".json"
    output = backup_cli.new_backup_path(config, suffix, scope)

    logger.info(
        "Backup export started: actor_id=%s scope=%s media=%s",
        user.id,
        scope,
        include_media,
    )
    try:
        payload, media = await backup_cli.prepare_backup(config, scope, include_media)
        await asyncio.to_thread(
            backup_cli.write_backup, output, payload, media, include_media=include_media
        )
    except (CliError, backup_limits.BackupLimitError) as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    library = payload["library"]
    logger.info(
        "Backup exported: actor_id=%s file=%s bytes=%s scope=%s games=%s users=%s media=%s",
        user.id,
        output.name,
        output.stat().st_size,
        scope,
        len(library.get("games") or []),
        len(payload["accounts"].get("users") or []),
        sum(len(files) for files in media.values()),
    )
    entry = _entry(output, _backups_root())
    entry["games"] = len(library.get("games") or [])
    entry["versions"] = len(library.get("versions") or [])
    entry["users"] = len(payload["accounts"].get("users") or [])
    entry["media"] = sum(len(files) for files in media.values())
    return entry


@router.get("/download")
async def download_backup(name: str, user: User = Depends(require_admin)):
    """Download a stored backup archive."""
    path = _resolve(name)
    logger.info(
        "Backup download: actor_id=%s filename=%s bytes=%s",
        user.id,
        path.name,
        path.stat().st_size,
    )
    return FileResponse(
        path,
        media_type="application/zip" if path.suffix.lower() == ".zip" else "application/json",
        filename=path.name,
    )


@router.delete("")
async def delete_backup(name: str, user: User = Depends(require_admin)):
    """Delete a stored backup archive."""
    path = _resolve(name)
    path.unlink()
    logger.warning("Backup deleted: actor_id=%s file=%s", user.id, name)
    return {"message": "备份已删除"}


async def store_uploaded_backup(file: UploadFile, destination: Path):
    limit = (backup_limits.MAX_JSON_BYTES if destination.suffix == ".json"
             else backup_limits.MAX_ARCHIVE_BYTES)
    size = 0
    try:
        with backup_cli.staged_backup(destination) as tmp:
            with tmp.open("wb") as handle:
                while chunk := await file.read(1024 * 1024):
                    size += len(chunk)
                    if size > limit:
                        raise HTTPException(status_code=413, detail="备份文件大小超过限制")
                    handle.write(chunk)
            payload = backup_cli.normalise_payload(backup_cli.read_backup_payload(tmp))
        return size, payload
    except CliError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except OSError as exc:
        raise HTTPException(status_code=500, detail="备份文件写入失败") from exc
    except (ValueError, TypeError) as exc:
        raise HTTPException(status_code=400, detail="备份文件无法解析") from exc
    finally:
        await file.close()


@router.post("/import")
async def import_backup(
    file: UploadFile = File(...),
    scope: str = Form(backup_cli.SCOPE_ALL),
    mode: str = Form(backup_cli.MODE_MERGE),
    media_policy: str = Form(backup_cli.MEDIA_SKIP),
    user: User = Depends(require_admin),
):
    """Restore a backup archive uploaded from the client."""
    if scope not in {backup_cli.SCOPE_ALL, backup_cli.SCOPE_PATCH, backup_cli.SCOPE_LIBRARY}:
        raise HTTPException(status_code=400, detail="未知的恢复范围")
    if mode not in {backup_cli.MODE_MERGE, backup_cli.MODE_REPLACE}:
        raise HTTPException(status_code=400, detail="未知的恢复方式")
    if media_policy not in {backup_cli.MEDIA_SKIP, backup_cli.MEDIA_OVERWRITE}:
        raise HTTPException(status_code=400, detail="未知的同名文件策略")

    suffix = Path(file.filename or "backup.zip").suffix.lower() or ".zip"
    if suffix not in BACKUP_SUFFIXES:
        raise HTTPException(status_code=400, detail="只支持 .zip 或 .json 备份文件")

    config = load_config()
    stored = _backups_root() / (
        f"uploaded-{backup_cli.utc_timestamp()}-{user.id}-{secrets.token_hex(3)}{suffix}"
    )
    size, payload = await store_uploaded_backup(file, stored)

    try:
        result = await backup_cli.apply_restore(
            config, stored, payload,
            scope=scope, mode=mode, media_policy=media_policy,
        )
    except (CliError, backup_limits.BackupLimitError) as exc:
        stored.unlink(missing_ok=True)
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except Exception as exc:
        stored.unlink(missing_ok=True)
        logger.error(
            "Backup import failed: stage=apply error=%s",
            redact_exception(exc),
        )
        raise HTTPException(status_code=500, detail="导入失败，请查看服务端日志") from exc
    except BaseException:
        stored.unlink(missing_ok=True)
        raise

    library = payload["library"]
    logger.warning(
        "Backup imported: actor_id=%s file=%s bytes=%s scope=%s mode=%s games=%s users=%s",
        user.id,
        stored.name,
        size,
        scope,
        mode,
        len(library.get("games") or []),
        len(payload["accounts"].get("users") or []),
    )
    return {
        "message": "备份已导入",
        "stored": stored.name,
        "games": len(library.get("games") or []),
        "versions": len(library.get("versions") or []),
        "users": len(payload["accounts"].get("users") or []),
        "stats": result.get("stats") or {},
        "relogin_required": bool(result.get("relogin_required")),
        "detail": result["lines"],
    }
