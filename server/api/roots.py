"""Root directory management API."""

from __future__ import annotations

import asyncio
import logging
import time

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from api.auth import get_current_user, require_admin
from config import load_config
from database import get_session
from models.user import User
from models.file_source import FileSource
from models.root_directory import RootDirectory
from schemas.common import MessageResponse
from services.file_source import SourceUnavailable, adapter_from_source, canonical_source_path, normalize_base_url, normalize_remote_path
from services.importer import (
    UnexpectedEmptyRoot,
    clear_scanned_games,
    import_from_root,
    verified_snapshots,
)
from services.task_stop import TaskStopped, checkpoint, run_id, signal_stop, stop_scope
from utils.log_redaction import redact_exception
from utils.secrets import encrypt_secret, redact_url
from utils.process_lock import process_lock, scan_lock_path

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/roots", tags=["roots"])
_scan_lock = asyncio.Lock()
_background_tasks: set[asyncio.Task] = set()
_scan_state = {
    "status": "idle",
    "roots_total": 0,
    "roots_completed": 0,
    "current_root": None,
    "started_at": None,
    "finished_at": None,
    "message": None,
}


def _set_scan_state(**updates):
    if updates.get("status") == "pending":
        if _scan_active():
            raise HTTPException(409, "已有扫描任务")
        updates['run_id'] = run_id()
        updates['empty_roots'] = []
    _scan_state.update(updates)


def _scan_state_response(user: User | None = None):
    state = dict(_scan_state)
    if user is None or user.role != "admin":
        # Library paths and per-root detail are management information.
        state.pop("current_root", None)
        state.pop('empty_roots', None)
    return state


def _scan_active() -> bool:
    """Return whether a scan is queued or currently holding the scan lock."""
    return _scan_state["status"] in {"pending", "running", "stopping"} or _scan_lock.locked()


class RootCreate(BaseModel):
    path: str = Field(min_length=1, max_length=1024)
    enable_batch_scrape: bool = True
    source_type: str = "local"
    source_id: int | None = None
    source_name: str | None = None
    base_url: str | None = None
    username: str | None = None
    password: str | None = None


class RootOut(BaseModel):
    id: int
    path: str
    source_type: str = "local"
    source_id: int | None = None
    source_name: str | None = None
    source_path: str | None = None
    enable_batch_scrape: bool

    model_config = {"from_attributes": True}


@router.get("", response_model=list[RootOut])
async def list_roots(user: User = Depends(require_admin), session: AsyncSession = Depends(get_session)):
    """List all root directories."""
    result = await session.execute(select(RootDirectory))
    return result.scalars().all()


@router.post("", response_model=RootOut, status_code=201)
async def add_root(
    body: RootCreate,
    user: User = Depends(require_admin),
    session: AsyncSession = Depends(get_session),
):
    """Add a new root directory."""
    source_type = body.source_type if body.source_type in {"local", "openlist"} else "local"
    source_id = body.source_id
    source_name = body.source_name
    source_path = body.path if source_type == "local" else normalize_remote_path(body.path)
    if source_type == "openlist":
        source = None
        if source_id:
            result = await session.execute(select(FileSource).where(FileSource.id == source_id))
            source = result.scalar_one_or_none()
            if source is None:
                raise HTTPException(status_code=404, detail="OpenList source not found")
        else:
            if not body.base_url:
                raise HTTPException(status_code=400, detail="OpenList URL is required")
            source = FileSource(
                name=source_name or body.base_url,
                type="openlist",
                base_url=normalize_base_url(body.base_url),
                username=body.username,
                password=encrypt_secret(body.password),
            )
            session.add(source)
            await session.flush()
            source_id = source.id
            logger.info(
                "OpenList source created from root dialog: actor_id=%s source_id=%s name=%s base_url=%s",
                user.id,
                source.id,
                source.name,
                redact_url(source.base_url),
            )
        adapter = adapter_from_source(source, "openlist")
        if not await asyncio.to_thread(adapter.exists, source_path):
            raise HTTPException(status_code=404, detail="OpenList path not found")
        source_name = source.name

    stored_path = canonical_source_path(source_type, source_id, source_path)
    # Check for duplicate
    existing = await session.execute(
        select(RootDirectory).where(RootDirectory.path == stored_path)
    )
    if existing.scalar_one_or_none():
        raise HTTPException(status_code=409, detail="Root directory already exists")

    root = RootDirectory(
        path=stored_path,
        source_type=source_type,
        source_id=source_id,
        source_name=source_name,
        source_path=source_path,
        enable_batch_scrape=body.enable_batch_scrape,
    )
    session.add(root)
    await session.commit()
    await session.refresh(root)
    logger.info(
        "Root added: actor_id=%s root_id=%s source_type=%s source_id=%s path=%s",
        user.id,
        root.id,
        root.source_type,
        root.source_id,
        root.source_path or root.path,
    )
    config = load_config()
    try:
        from api.settings import _load_scan_settings
        _load_scan_settings(config)
        if getattr(config, "_auto_scan", False):
            _bg_scan(config, [root.id], update_last=True)
    except Exception as exc:
        logger.error(
            "Failed to start auto-scan for new root: %s",
            redact_exception(exc),
        )
    return root


@router.put("/{root_id}", response_model=RootOut)
async def update_root(
    root_id: int,
    body: RootCreate,
    user: User = Depends(require_admin),
    session: AsyncSession = Depends(get_session),
):
    """Update a root directory without deleting the existing record."""
    result = await session.execute(select(RootDirectory).where(RootDirectory.id == root_id))
    root = result.scalar_one_or_none()
    if root is None:
        raise HTTPException(status_code=404, detail="Root directory not found")

    source_type = body.source_type if body.source_type in {"local", "openlist"} else "local"
    source_id = body.source_id
    source_name = body.source_name
    source_path = body.path if source_type == "local" else normalize_remote_path(body.path)
    if source_type == "openlist":
        source = None
        if source_id:
            result = await session.execute(select(FileSource).where(FileSource.id == source_id))
            source = result.scalar_one_or_none()
            if source is None:
                raise HTTPException(status_code=404, detail="OpenList source not found")
        else:
            if not body.base_url:
                raise HTTPException(status_code=400, detail="OpenList source must be selected first")
            source = FileSource(
                name=source_name or body.base_url,
                type="openlist",
                base_url=normalize_base_url(body.base_url),
                username=body.username,
                password=encrypt_secret(body.password),
            )
            session.add(source)
            await session.flush()
            source_id = source.id
            logger.info(
                "OpenList source created from root dialog: actor_id=%s source_id=%s name=%s base_url=%s",
                user.id,
                source.id,
                source.name,
                redact_url(source.base_url),
            )
        adapter = adapter_from_source(source, "openlist")
        if not await asyncio.to_thread(adapter.exists, source_path):
            raise HTTPException(status_code=404, detail="OpenList path not found")
        source_name = source.name

    stored_path = canonical_source_path(source_type, source_id, source_path)
    existing = await session.execute(
        select(RootDirectory).where(RootDirectory.path == stored_path, RootDirectory.id != root_id)
    )
    if existing.scalar_one_or_none():
        raise HTTPException(status_code=409, detail="Root directory already exists")

    root.path = stored_path
    root.source_type = source_type
    root.source_id = source_id
    root.source_name = source_name
    root.source_path = source_path
    root.enable_batch_scrape = body.enable_batch_scrape
    await session.commit()
    await session.refresh(root)
    logger.info(
        "Root updated: actor_id=%s root_id=%s source_type=%s source_id=%s path=%s",
        user.id,
        root.id,
        root.source_type,
        root.source_id,
        root.source_path or root.path,
    )
    return root


@router.delete("/{root_id}", response_model=MessageResponse)
async def delete_root(
    root_id: int,
    user: User = Depends(require_admin),
    session: AsyncSession = Depends(get_session),
):
    """Remove a root directory (does not delete files)."""
    result = await session.execute(
        select(RootDirectory).where(RootDirectory.id == root_id)
    )
    root = result.scalar_one_or_none()
    if root is None:
        raise HTTPException(status_code=404, detail="Root directory not found")

    logger.info(
        "Root deleted: actor_id=%s root_id=%s path=%s",
        user.id,
        root.id,
        root.source_path or root.path,
    )
    await session.delete(root)
    await session.commit()
    return MessageResponse(message="Root directory removed")


def _bg_scan(config, root_ids: list[int], update_last: bool = False, **options):
    """Background scan: runs in its own async task with independent session."""
    key = _scan_state.get('run_id')
    async def _run():
        try:
            result = await _run_scan(config, root_ids=root_ids, update_last=update_last, key=key, **options)
            if result.get("skipped"):
                logger.info("Background scan skipped: scan already running")
                if _scan_state["status"] == "pending":
                    _set_scan_state(
                        status="failed",
                        current_root=None,
                        finished_at=time.time(),
                        message="其他扫描或恢复任务正在运行，本次扫描未启动，请稍后重试",
                    )
        except Exception as exc:
            logger.error("Background scan failed: %s", redact_exception(exc))
            _set_scan_state(
                status="failed",
                current_root=None,
                finished_at=time.time(),
                message="扫描失败，请查看服务端日志",
            )
    task = asyncio.create_task(_run())
    _background_tasks.add(task)
    task.add_done_callback(_background_tasks.discard)


@router.post("/refresh-all")
async def refresh_all_roots(
    user: User = Depends(require_admin),
    session: AsyncSession = Depends(get_session),
):
    """Trigger re-scan of ALL root directories in background. Returns immediately."""
    if _scan_active():
        raise HTTPException(status_code=409, detail="扫描正在运行，请等待当前扫描完成后再试")
    result = await session.execute(select(RootDirectory))
    roots = result.scalars().all()
    config = load_config()
    from api.settings import _load_scan_settings
    _load_scan_settings(config)
    _set_scan_state(
        status="pending",
        roots_total=len(roots),
        roots_completed=0,
        current_root=None,
        started_at=time.time(),
        finished_at=None,
        message="扫描任务正在排队",
    )
    _bg_scan(config, [r.id for r in roots], update_last=True)
    logger.info("Full library scan started: actor_id=%s roots=%s", user.id, len(roots))
    return {"message": "扫描已在后台启动", "roots": len(roots), 'run_id': _scan_state['run_id']}


@router.get("/scan-status")
async def get_scan_status(user: User = Depends(get_current_user)):
    """Return the current background game-library scan state."""
    return _scan_state_response(user)


@router.post("/scan-status/{key}/stop")
async def stop_root_scan(key: str, user: User = Depends(require_admin)):
    if key != _scan_state.get("run_id"):
        raise HTTPException(409, "任务已更换，请刷新进度")
    if _scan_state["status"] in {"pending", "running", "stopping"}:
        _set_scan_state(status="stopping", message="正在停止任务")
        signal_stop(key)
    return _scan_state_response(user)


@router.post("/clear-and-refresh")
async def clear_and_refresh_roots(
    user: User = Depends(require_admin),
    session: AsyncSession = Depends(get_session),
):
    """Re-scan the library while keeping manual entries and locked metadata."""
    if _scan_active():
        raise HTTPException(status_code=409, detail="扫描正在运行，请等待当前扫描完成后再清空重扫")

    config = load_config()
    with process_lock(scan_lock_path(config.data_path), blocking=False) as locked:
        if not locked:
            raise HTTPException(status_code=409, detail="扫描正在运行，请等待当前扫描完成后再清空重扫")

        from models.agent import AgentJob
        pending_agent = (
            await session.execute(
                select(AgentJob.id)
                .where(AgentJob.status.in_(["pending", "running"]))
                .limit(1)
            )
        ).first()
        if pending_agent:
            raise HTTPException(status_code=409, detail="智能体任务正在运行，请结束后再清空重扫")
        from models.scrape_job import ACTIVE_SCRAPE, ScrapeJob

        if (
            await session.scalar(
                select(ScrapeJob.id).where(ScrapeJob.status.in_(ACTIVE_SCRAPE)).limit(1)
            )
            is not None
        ):
            raise HTTPException(409, "刮削任务正在运行，未执行清理")
        root_ids = list((await session.scalars(select(RootDirectory.id))).all())
        if not root_ids:
            raise HTTPException(409, '没有可验证的游戏根目录，未执行清理')
        _set_scan_state(
            status='pending', roots_total=len(root_ids),
            roots_completed=0,
            current_root=None,
            started_at=time.time(),
            finished_at=None,
            message="等待验证所有根目录，尚未清理",
        )
    _bg_scan(config, root_ids, update_last=True, clear_existing=True)
    logger.info('Queued library rebuild: roots=%s', len(root_ids))
    return {
        "status": "pending", "message": "后台将先验证所有根目录，再重建扫描记录",
        'run_id': _scan_state['run_id'],
        "roots": len(root_ids),
    }


@router.post("/{root_id}/refresh")
async def refresh_root(
    root_id: int,
    user: User = Depends(require_admin),
    session: AsyncSession = Depends(get_session),
    confirm_empty: bool = False,
    after_run: str | None = None,
):
    """Re-scan a root directory and import/update games."""
    if _scan_active():
        raise HTTPException(status_code=409, detail="扫描正在运行，请等待当前扫描完成后再试")
    if confirm_empty and (
        not after_run
        or after_run != _scan_state.get("run_id")
        or root_id not in _scan_state.get("empty_roots", [])
    ):
        raise HTTPException(409, '确认已过期，请先重新扫描此目录')
    result = await session.execute(
        select(RootDirectory).where(RootDirectory.id == root_id)
    )
    root = result.scalar_one_or_none()
    if root is None:
        raise HTTPException(status_code=404, detail="Root directory not found")

    config = load_config()
    from api.settings import _load_scan_settings
    _load_scan_settings(config)
    _set_scan_state(
        status="pending",
        roots_total=1,
        roots_completed=0,
        current_root=root.source_path or root.path,
        started_at=time.time(),
        finished_at=None,
        message="扫描任务正在排队",
    )
    _bg_scan(config, [root_id], update_last=True, confirmed_empty_root=root_id if confirm_empty else None)
    logger.info(
        "Root scan started: actor_id=%s root_id=%s path=%s",
        user.id,
        root_id,
        root.source_path or root.path,
    )
    return {
        "message": "扫描已在后台启动",
        "root_id": root_id,
        "run_id": _scan_state["run_id"],
    }


async def _run_scan(
    config, root_ids: list[int] | None = None, update_last: bool = False, key=None, **options
):
    if key is None:
        if _scan_active():
            return {"skipped": True}
        _set_scan_state(
            status="pending",
            started_at=time.time(),
            finished_at=None,
            current_root=None,
            roots_total=0,
            roots_completed=0,
            message=None,
        )
        key = _scan_state["run_id"]
    with stop_scope(key):
        try:
            if _scan_state["status"] == "stopping":
                raise TaskStopped()
            result = await _run_root_worker(config, root_ids, update_last, **options)
            if result.get("skipped"):
                _set_scan_state(
                    status="failed",
                    finished_at=time.time(),
                    message="其他扫描或恢复任务正在运行，本次扫描未启动",
                )
            return result
        except SourceUnavailable as exc:
            _set_scan_state(
                status="failed",
                current_root=None,
                finished_at=time.time(),
                message=str(exc),
                empty_roots=[exc.root_id]
                if isinstance(exc, UnexpectedEmptyRoot)
                else [],
            )
            return {"status": "failed", "run_id": key}
        except TaskStopped:
            _set_scan_state(
                status="cancelled",
                current_root=None,
                finished_at=time.time(),
                message="任务已停止，已完成目录的结果保留",
            )
            if update_last:
                from api.settings import _mark_auto_scan

                _mark_auto_scan(config, time.time())
            return {"status": "cancelled", "run_id": key}
        except BaseException:
            _set_scan_state(
                status="failed",
                current_root=None,
                finished_at=time.time(),
                message="扫描未完成",
            )
            raise


async def _run_root_worker(config, root_ids, update_last, *, clear_existing=False, confirmed_empty_root=None):
    """Internal helper for auto-scan. Runs refresh-all without HTTP."""
    if _scan_lock.locked():
        return {"skipped": True, "reason": "scan already running"}
    import database
    from sqlalchemy import select
    from api.settings import _load_scan_settings, _mark_auto_scan
    _load_scan_settings(config)
    total_games = 0
    with process_lock(scan_lock_path(config.data_path), blocking=False) as locked:
        if not locked:
            return {"skipped": True, "reason": "scan already running"}
        async with _scan_lock:
            async with database._session_factory() as session:
                query = select(RootDirectory)
                if root_ids is not None:
                    query = query.where(RootDirectory.id.in_(root_ids))
                result = await session.execute(query)
                roots = result.scalars().all()
                checkpoint()
                _set_scan_state(
                    status="running",
                    roots_total=len(roots),
                    roots_completed=0,
                    current_root=None,
                    started_at=time.time(),
                    finished_at=None,
                    message=None,
                )
                failed_roots: list[int] = []
                empty_roots = []
                if clear_existing and set(root_ids) != {r.id for r in roots}:
                    raise SourceUnavailable("根目录配置已变化，未执行清理")
                snapshots = (
                    await verified_snapshots(roots, config, session)
                    if clear_existing
                    else {}
                )
                targets = [(r.id, r.source_path or r.path) for r in roots]
                for root_id, path in targets:
                    checkpoint()
                    _set_scan_state(
                        current_root=path,
                        roots_completed=_scan_state["roots_completed"],
                    )
                    try:
                        if clear_existing:
                            await clear_scanned_games(session, [root_id])
                        stats = await import_from_root(
                            root_id,
                            config,
                            session,
                            scan_override=snapshots.get(root_id),
                            preserve_unseen=clear_existing,
                            confirm_empty=root_id == confirmed_empty_root,
                        )
                        total_games += stats.get("total_games", 0)
                    except Exception as exc:
                        await session.rollback()
                        logger.error(
                            "Scan root %s failed: %s",
                            root_id,
                            redact_exception(exc),
                        )
                        failed_roots.append(root_id)
                        if isinstance(exc, UnexpectedEmptyRoot):
                            empty_roots.append(root_id)
                    _set_scan_state(roots_completed=_scan_state['roots_completed'] + 1)
            checkpoint()
            if update_last:
                try:
                    _mark_auto_scan(config, time.time())
                except Exception as exc:
                    logger.error(
                        "Failed to persist last auto-scan time: %s",
                        redact_exception(exc),
                    )
            if failed_roots:
                _set_scan_state(
                    status="failed",
                    current_root=None,
                    finished_at=time.time(),
                    empty_roots=empty_roots,
                    message=(
                        f"目录 {failed_roots} 的枚举或入库未完成，旧条目已保留；请检查挂载、网盘分页和访问权限"
                    ),
                )
                return {
                    "status": "failed",
                    "total_games": total_games,
                    "roots_scanned": len(roots),
                    "failed_roots": failed_roots,
                }
            _set_scan_state(
                status="completed",
                current_root=None,
                finished_at=time.time(),
                message=f"扫描完成，共处理 {len(roots)} 个目录",
            )
            return {"total_games": total_games, "roots_scanned": len(roots)}
