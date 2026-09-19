"""Server backup management API (admin only)."""

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

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/backup", tags=["backup"])

BACKUP_SUFFIXES = {".zip", ".json"}
BACKUP_PREFIXES = ("sena-backup-", "uploaded-")


def _backups_root() -> Path:
    config = load_config()
    root = Path(config.data_path or "/data") / "backups"
    root.mkdir(parents=True, exist_ok=True)
    return root


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

    payload = await backup_cli.build_payload(config, scope=scope)
    media = backup_cli.collect_media(config, payload)
    payload["media"] = {kind: [path.name for path in files] for kind, files in media.items()}
    await asyncio.to_thread(
        backup_cli.write_backup,
        output,
        payload,
        media,
        include_media=include_media,
    )

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
    size = 0
    try:
        with stored.open("wb") as handle:
            while True:
                chunk = await file.read(1024 * 1024)
                if not chunk:
                    break
                handle.write(chunk)
                size += len(chunk)
    except OSError as exc:
        stored.unlink(missing_ok=True)
        raise HTTPException(status_code=500, detail="备份文件写入失败") from exc
    finally:
        await file.close()

    try:
        payload = backup_cli.normalise_payload(backup_cli.read_backup_payload(stored))
    except CliError as exc:
        stored.unlink(missing_ok=True)
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except Exception as exc:
        stored.unlink(missing_ok=True)
        logger.warning("Backup import failed to read archive: %s", type(exc).__name__)
        raise HTTPException(status_code=400, detail="备份文件无法解析") from exc

    try:
        result = await backup_cli.apply_restore(
            config, stored, payload,
            scope=scope, mode=mode, media_policy=media_policy,
        )
    except CliError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except Exception as exc:
        logger.error("Backup import failed: %s", type(exc).__name__)
        raise HTTPException(status_code=500, detail="导入失败，请查看服务端日志") from exc

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
        "detail": result["lines"],
    }
