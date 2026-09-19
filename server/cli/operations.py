"""Local maintenance commands for senacli."""

from __future__ import annotations

import subprocess
import time
from datetime import datetime
from pathlib import Path

import database as db
from cli.common import (
    choose,
    confirm,
    confirm_phrase,
    echo,
    fail,
    in_docker,
    install_root,
    installer_path,
    is_interactive,
    prepare_app,
    print_kv,
    print_table,
    read_version_metadata,
    remote_source_sha,
    run_command,
    short_sha,
    uninstaller_path,
)
from config import Config
from models.file_source import FileSource
from models.game import Game, GameTag, GameVersion
from models.root_directory import RootDirectory
from models.scrape_job import JobStatus, ScrapeJob
from models.tag import Tag
from models.user import User
from services.importer import cleanup_empty_companies, import_from_root
from services.scraper.orchestrator import run_batch_scrape
from sqlalchemy import delete, func, select
from sqlalchemy.ext.asyncio import AsyncSession
from utils.process_lock import process_lock, scan_lock_path


DEFAULT_REPO_URL = "https://github.com/404-GCross/Sena-Repo.git"
CHANNEL_REFS = {"dev": "dev", "release": "main"}
SCRAPE_MODES = ("none", "missing", "overwrite", "metadata", "images")


def _status_value(value) -> str:
    return value.value if hasattr(value, "value") else str(value or "")


def _format_dt(value: datetime | None) -> str:
    return value.strftime("%Y-%m-%d %H:%M:%S") if value else "-"


def _systemd_value(name: str, prop: str) -> str:
    try:
        proc = subprocess.run(
            ["systemctl", "show", name, f"--property={prop}", "--value"],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except OSError:
        return ""
    if proc.returncode != 0:
        return ""
    return proc.stdout.strip()


def _systemd_is_active(name: str) -> str:
    try:
        proc = subprocess.run(
            ["systemctl", "is-active", name],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except OSError:
        return "unknown"
    return proc.stdout.strip() or "unknown"


def _detect_server_pid() -> int | None:
    if in_docker():
        return 1 if Path("/proc/1").exists() else None
    pid_text = _systemd_value("sena-repo.service", "MainPID")
    if pid_text.isdigit() and int(pid_text) > 0:
        return int(pid_text)
    try:
        proc = subprocess.run(
            ["pgrep", "-fo", "uvicorn.*main:app|python.*main:app"],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except OSError:
        return None
    value = proc.stdout.strip()
    return int(value) if proc.returncode == 0 and value.isdigit() else None


def _process_stats(pid: int | None) -> tuple[str, str, str]:
    if not pid:
        return "-", "-", "-"
    try:
        proc = subprocess.run(
            ["ps", "-p", str(pid), "-o", "%cpu=,rss=,etime="],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
        parts = proc.stdout.split()
        if proc.returncode == 0 and len(parts) >= 3:
            cpu = f"{float(parts[0]):.1f}%"
            rss = f"{int(parts[1]) / 1024:.1f} MB"
            return cpu, rss, parts[2]
    except (OSError, ValueError):
        pass

    status_path = Path(f"/proc/{pid}/status")
    if status_path.is_file():
        for line in status_path.read_text(encoding="utf-8", errors="ignore").splitlines():
            if line.startswith("VmRSS:"):
                parts = line.split()
                if len(parts) >= 2 and parts[1].isdigit():
                    return "-", f"{int(parts[1]) / 1024:.1f} MB", "-"
    return "-", "-", "-"


def _parse_sources(value: str | None) -> list[str] | None:
    if not value:
        return None
    sources = [item.strip() for item in value.split(",") if item.strip()]
    return sources or None


def _resolve_scrape_mode(requested: str | None) -> str:
    if requested:
        return requested
    if not is_interactive():
        return "none"
    return choose(
        "扫描完成后是否刮削？",
        [
            ("none", "只扫描，不刮削"),
            ("missing", "只刮削缺失封面的游戏"),
            ("overwrite", "覆盖刮削全部游戏"),
            ("metadata", "只补文本元数据"),
            ("images", "只刷新图片"),
        ],
        default="none",
    )


async def _active_scrape_job(session: AsyncSession) -> ScrapeJob | None:
    result = await session.execute(
        select(ScrapeJob)
        .where(ScrapeJob.status.in_([JobStatus.PENDING, JobStatus.RUNNING]))
        .order_by(ScrapeJob.created_at.desc())
    )
    return result.scalars().first()


async def _run_scan(
    config: Config,
    *,
    root_ids: list[int] | None,
    scrape_mode: str,
    sources: list[str] | None,
    update_last: bool,
) -> int:
    from api.settings import _load_scan_settings, _mark_auto_scan

    _load_scan_settings(config)
    lock_path = scan_lock_path(config.data_path)
    with process_lock(lock_path, blocking=False) as locked:
        if not locked:
            fail("已有扫描任务正在运行，请稍后再试", 5)

        async with db._session_factory() as session:
            query = select(RootDirectory).order_by(RootDirectory.id)
            if root_ids:
                query = query.where(RootDirectory.id.in_(root_ids))
            result = await session.execute(query)
            roots = list(result.scalars().all())
            if not roots:
                echo("没有可扫描的根目录")
                return 0

            rows = []
            total_games = 0
            for root in roots:
                label = root.source_path or root.path
                echo(f"扫描目录 #{root.id}: {label}")
                try:
                    stats = await import_from_root(root.id, config, session)
                    total_games += int(stats.get("total_games") or 0)
                    rows.append(
                        [
                            root.id,
                            root.source_type or "local",
                            int(stats.get("new_versions") or 0),
                            int(stats.get("total_games") or 0),
                            int(stats.get("orphaned") or 0),
                        ]
                    )
                except Exception as exc:
                    await session.rollback()
                    rows.append([root.id, root.source_type or "local", "ERROR", "-", "-"])
                    echo(f"目录 #{root.id} 扫描失败: {exc}", err=True)

            print_table(["Root", "Type", "NewVersions", "Games", "Orphaned"], rows)
            echo(f"扫描完成，共处理 {len(roots)} 个目录，当前有效游戏 {total_games} 个")

            if update_last:
                try:
                    _mark_auto_scan(config, time.time())
                except Exception as exc:
                    echo(f"记录自动扫描时间失败: {exc}", err=True)

            if scrape_mode == "none":
                return 0

            active_job = await _active_scrape_job(session)
            if active_job is not None:
                fail(f"已有刮削任务正在运行: #{active_job.id}", 5)

            now = datetime.utcnow()
            job = ScrapeJob(
                status=JobStatus.PENDING,
                current_stage="queued",
                heartbeat_at=now,
                updated_at=now,
            )
            session.add(job)
            await session.commit()
            await session.refresh(job)
            echo(f"开始批量刮削: job #{job.id}, mode={scrape_mode}")
            stats = await run_batch_scrape(
                config,
                None,
                session,
                job,
                sources=sources,
                mode=scrape_mode,
            )
            echo(
                "刮削完成: "
                f"total={stats.get('total', 0)}, "
                f"successful={stats.get('successful', 0)}, "
                f"failed={stats.get('failed', 0)}"
            )
    return 0


async def cmd_status(args) -> int:
    config = await prepare_app()
    metadata = read_version_metadata()
    pid = _detect_server_pid()
    cpu, memory, uptime = _process_stats(pid)
    with process_lock(scan_lock_path(config.data_path), blocking=False) as scan_idle:
        scan_state = "idle" if scan_idle else "running"

    async with db._session_factory() as session:
        counts = {}
        for key, model in (
            ("games", Game),
            ("versions", GameVersion),
            ("tags", Tag),
            ("roots", RootDirectory),
            ("file_sources", FileSource),
            ("users", User),
        ):
            counts[key] = int(
                (await session.execute(select(func.count()).select_from(model))).scalar_one()
                or 0
            )

        latest_job = (
            await session.execute(select(ScrapeJob).order_by(ScrapeJob.id.desc()).limit(1))
        ).scalar_one_or_none()
        active_job = await _active_scrape_job(session)
        roots = list(
            (
                await session.execute(select(RootDirectory).order_by(RootDirectory.id))
            ).scalars().all()
        )

    service_state = "docker" if in_docker() else _systemd_is_active("sena-repo.service")
    print_kv(
        [
            ("Install root", install_root()),
            ("Data path", config.data_path),
            ("Games path", config.games_path),
            ("Patch dir", config.patch_dir),
            ("Bind", f"{config.server.host}:{config.server.port}"),
            ("Deployment", "docker" if in_docker() else "bare-metal/source"),
            ("Service", service_state),
            ("Server PID", pid or "-"),
            ("CPU", cpu),
            ("Memory", memory),
            ("Uptime", uptime),
            ("Source ref", metadata.get("SOURCE_REF", "-")),
            ("Source SHA", short_sha(metadata.get("SOURCE_SHA", ""))),
            ("Scan state", scan_state),
            ("Games", counts["games"]),
            ("Versions", counts["versions"]),
            ("Tags", counts["tags"]),
            ("Roots", counts["roots"]),
            ("File sources", counts["file_sources"]),
            ("Users", counts["users"]),
        ]
    )
    if latest_job is not None:
        echo()
        print_kv(
            [
                ("Latest scrape job", f"#{latest_job.id} {_status_value(latest_job.status)}"),
                ("Progress", f"{latest_job.processed_games or latest_job.completed_games or 0}/{latest_job.total_games or 0}"),
                ("Successful", latest_job.successful_games or 0),
                ("Failed", latest_job.failed_games or 0),
                ("Current game", latest_job.current_game or "-"),
                ("Stage", latest_job.current_stage or "-"),
                ("Updated", _format_dt(latest_job.updated_at)),
            ]
        )
    if active_job is not None:
        echo(f"当前有刮削任务正在运行: #{active_job.id}")
    if args.roots and roots:
        echo()
        print_table(
            ["ID", "Type", "Source", "Path", "BatchScrape"],
            [
                [
                    root.id,
                    root.source_type or "local",
                    root.source_name or "-",
                    root.source_path or root.path,
                    "yes" if root.enable_batch_scrape else "no",
                ]
                for root in roots
            ],
        )
    return 0


async def cmd_scan(args) -> int:
    config = await prepare_app()
    scrape_mode = _resolve_scrape_mode(args.scrape)
    return await _run_scan(
        config,
        root_ids=args.root_id,
        scrape_mode=scrape_mode,
        sources=_parse_sources(args.sources),
        update_last=True,
    )


async def cmd_clear(args) -> int:
    config = await prepare_app()
    if not args.force:
        if not confirm("确认清空所有游戏条目并重新扫描？"):
            echo("已取消")
            return 130
        if not confirm_phrase(
            "这会删除游戏、版本与游戏标签关联；目录配置、用户、刮削源配置会保留。",
            "CLEAR",
        ):
            echo("已取消")
            return 130

    async with db._session_factory() as session:
        cleared_games = int(
            (await session.execute(select(func.count()).select_from(Game))).scalar_one() or 0
        )
        await session.execute(delete(GameTag))
        await session.execute(delete(GameVersion))
        await session.execute(delete(Game))
        await cleanup_empty_companies(session)
        await session.commit()
        echo(f"已清空游戏条目: {cleared_games}")

    scrape_mode = _resolve_scrape_mode(args.scrape)
    return await _run_scan(
        config,
        root_ids=None,
        scrape_mode=scrape_mode,
        sources=_parse_sources(args.sources),
        update_last=True,
    )


def cmd_update(args) -> int:
    if in_docker():
        echo("Docker 部署不能在容器内自更新。")
        echo("请在宿主机 pull 新镜像并重建容器，例如：")
        echo("  docker pull 404gcross/sena-repo:pre-release")
        echo("  docker stop sena-repo && docker rm sena-repo")
        echo("  docker run ... 404gcross/sena-repo:pre-release")
        return 2

    metadata = read_version_metadata()
    repo_url = args.repo_url or metadata.get("SOURCE_URL") or DEFAULT_REPO_URL
    repo_ref = args.ref or CHANNEL_REFS[args.channel]
    current_sha = metadata.get("SOURCE_SHA", "")
    remote_sha = remote_source_sha(repo_url, repo_ref)
    if not remote_sha:
        fail("无法检查远程版本；请确认 git 可用且网络可访问 GitHub", 2)
    echo(f"当前版本: {short_sha(current_sha)}")
    echo(f"远程版本: {short_sha(remote_sha)} ({repo_ref})")
    if current_sha == remote_sha and not args.force:
        echo("已经是最新版本")
        return 0
    if not args.yes and not confirm(f"确认更新到 {repo_ref}@{short_sha(remote_sha)}？"):
        echo("已取消")
        return 130
    env = {
        "SENA_REPO_URL": repo_url,
        "SENA_REPO_REF": repo_ref,
    }
    return run_command(["bash", str(installer_path()), "--update"], env=env)


def cmd_uninstall(args) -> int:
    if in_docker():
        echo("Docker 部署不能在容器内卸载宿主机服务。")
        echo("请在宿主机停止并删除容器；如需清数据，再删除挂载的数据目录。")
        return 2
    command = ["bash", str(uninstaller_path())]
    if args.purge_data:
        command.append("--purge-data")
    elif args.keep_data:
        command.append("--keep-data")
    return run_command(command)
