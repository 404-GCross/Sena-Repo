"""Backup and restore commands for senacli.

A backup is a single zip archive:

    backup.json            structured data (patch rules, library, accounts)
    media/covers/<key>     cover images referenced by the library
    media/backgrounds/<key> background images
    media/avatars/<key>    user avatars

Entries reference each other by backup-local keys (``src-1``, ``root-2``,
``game-3``) and media by content hash, so a restore never has to guess which
local row or file a backup entry meant. Only the current schema is accepted;
older archives must be re-exported with this version.

`senacli backup` writes a zip by default; `--json-only` falls back to a plain
JSON file without media. `senacli restore` asks for the few decisions that
matter and `-y` accepts the defaults (everything, merge, keep existing images).
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import logging
import re
import secrets
import shutil
import sqlite3
import zipfile
from contextlib import ExitStack
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from sqlalchemy import delete, func, select
from sqlalchemy.orm import selectinload

import database as db
from cli import patch_rules
from cli.common import choose, confirm, echo, fail, prepare_app
from models.file_source import FileSource, SteamPatchRoot
from models.game import (
    Company,
    Game,
    GameTag,
    GameVersion,
    PlatformCategory,
    PlatformCategoryRule,
)
from models.ignore_list import IgnoreList
from models.root_directory import RootDirectory
from models.tag import Tag
from models.user import User, UserSession
from services.file_source import canonical_source_path
from services.platforms import SYSTEM_CATEGORY_NAME, ensure_category
from utils.process_lock import process_lock, scan_lock_path
from utils.log_redaction import redact_exception
from utils.secrets import (
    SCRAPER_SECRET_KEYS,
    decrypt_secret,
    encrypt_secret,
    is_encrypted,
)

logger = logging.getLogger(__name__)

KIND = "sena_backup"
SCHEMA_VERSION = 5
JSON_NAME = "backup.json"
MEDIA_KINDS = ("covers", "backgrounds", "avatars")
# Media file names are content hashes produced by this module; anything else is
# rejected so a crafted archive cannot write outside the media directory.
MEDIA_KEY_RE = re.compile(
    r"^[A-Za-z0-9_-]{8,64}\.(?:jpg|jpeg|png|gif|webp)$", re.IGNORECASE
)
SCOPE_ALL = "all"
SCOPE_PATCH = "patch"
SCOPE_LIBRARY = "library"
EXPORT_SCOPES = (SCOPE_ALL, SCOPE_LIBRARY, SCOPE_PATCH)
MODE_MERGE = "merge"
MODE_REPLACE = "replace"
MEDIA_SKIP = "skip"
MEDIA_OVERWRITE = "overwrite"

ENTRY_SOURCES = ("library", "manual", "metadata")
LIBRARY_SECTIONS = (
    "roots",
    "games",
    "versions",
    "tags",
    "game_tags",
    "platform_categories",
    "companies",
    "ignore_list",
)


def _has_library_section(library: dict[str, Any]) -> bool:
    """Patch-only archives carry file sources but no library sections."""
    return any(key in library for key in LIBRARY_SECTIONS)


def utc_timestamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")


def utc_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _iso(value: datetime | None) -> str | None:
    if value is None:
        return None
    if value.tzinfo is not None:
        value = value.astimezone(timezone.utc).replace(tzinfo=None)
    return value.replace(microsecond=0).isoformat() + "Z"


def _parse_dt(value: Any) -> datetime | None:
    if not value:
        return None
    text = str(value).strip()
    try:
        parsed = datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is not None:
        parsed = parsed.astimezone(timezone.utc).replace(tzinfo=None)
    return parsed


def _basename(value: Any) -> str | None:
    text = str(value or "").replace("\\", "/").strip()
    if not text:
        return None
    return text.rsplit("/", 1)[-1] or None


def backup_dir(config) -> Path:
    return Path(config.data_path or "/data") / "backups" / "sena-backup"


def backup_file_name(suffix: str, scope: str = SCOPE_ALL) -> str:
    """Unique backup file name; the random tail avoids same-second collisions."""
    return f"sena-backup-{utc_timestamp()}-{scope}-{secrets.token_hex(3)}{suffix}"


def new_backup_path(config, suffix: str, scope: str = SCOPE_ALL) -> Path:
    return backup_dir(config) / backup_file_name(suffix, scope)


def media_dirs(config) -> dict[str, Path]:
    return {
        "covers": Path(config.covers_path),
        "backgrounds": Path(config.backgrounds_path),
        "avatars": Path(config.data_path or "/data") / "avatars",
    }


def resolve_output(args, config, suffix: str, scope: str = SCOPE_ALL) -> Path:
    directory = getattr(args, "directory", None)
    output = getattr(args, "output", None)
    if directory and output:
        fail("不能同时指定备份目录和 -o 输出文件", 2)
    if directory:
        target = Path(directory).expanduser()
        if target.suffix.lower() in {".json", ".zip"}:
            fail("backup 后面的路径表示目录；指定文件请使用 -o", 2)
        return target / backup_file_name(suffix, scope)
    if output:
        target = Path(output).expanduser()
        if target.exists() and target.is_dir():
            return target / backup_file_name(suffix, scope)
        return target
    return new_backup_path(config, suffix, scope)


# ── export ──


async def _export_file_sources(session) -> list[dict[str, Any]]:
    rows = list(
        (await session.execute(select(FileSource).order_by(FileSource.id))).scalars()
    )
    return [
        {
            "key": f"src-{index}",
            "name": source.name,
            "type": source.type,
            "base_url": source.base_url,
            "username": source.username,
            "password": _safe_decrypt(source.password),
            "enabled": bool(source.enabled),
        }
        for index, source in enumerate(rows, 1)
    ]


async def _export_library(session) -> dict[str, list[dict[str, Any]]]:
    company_rows = list((await session.execute(select(Company))).scalars())
    companies = {c.id: c.name for c in company_rows}
    source_rows = list(
        (await session.execute(select(FileSource).order_by(FileSource.id))).scalars()
    )
    source_keys = {source.id: f"src-{index}" for index, source in enumerate(source_rows, 1)}
    root_rows = list(
        (await session.execute(select(RootDirectory).order_by(RootDirectory.id))).scalars()
    )
    root_keys = {root.id: f"root-{index}" for index, root in enumerate(root_rows, 1)}
    games = list((await session.execute(select(Game).order_by(Game.id))).scalars())
    game_keys = {game.id: f"game-{index}" for index, game in enumerate(games, 1)}
    versions = list(
        (await session.execute(select(GameVersion).order_by(GameVersion.id))).scalars()
    )
    tags = list((await session.execute(select(Tag))).scalars())
    game_tags = list((await session.execute(select(GameTag))).scalars())
    ignored = list((await session.execute(select(IgnoreList))).scalars())

    tag_names = {t.id: t.name for t in tags}
    root_paths = {r.id: r.path for r in root_rows}

    return {
        "file_sources": await _export_file_sources(session),
        "roots": [
            {
                "key": root_keys[root.id],
                "path": root.path,
                "source_type": root.source_type,
                "source_key": source_keys.get(root.source_id),
                "source_name": root.source_name,
                "source_path": root.source_path,
                "enable_batch_scrape": bool(root.enable_batch_scrape),
            }
            for root in root_rows
        ],
        "companies": [
            {"name": c.name, "created_at": _iso(c.created_at)} for c in company_rows
        ],
        "games": [
            {
                "key": game_keys[game.id],
                "name": game.name,
                "company": companies.get(game.company_id),
                "root_key": root_keys.get(game.root_id),
                "root": root_paths.get(game.root_id),
                "folder_path": game.folder_path,
                "entry_source": game.entry_source,
                "cover": _basename(game.cover_path),
                "background": _basename(game.bg_path),
                "is_nsfw": bool(game.is_nsfw),
                "developer": game.developer,
                "alias": game.alias,
                "description": game.description,
                "release_date": game.release_date,
                "vndb_id": game.vndb_id,
                "steam_id": game.steam_id,
                "bangumi_id": game.bangumi_id,
                "hikarinagi_id": game.hikarinagi_id,
                "nextmoe_id": game.nextmoe_id,
                "length": game.length or 0,
                "length_minutes": game.length_minutes or 0,
                "metadata_locked": bool(game.metadata_locked),
                "name_locked": bool(game.name_locked),
                "is_deleted": bool(game.is_deleted),
                "imported_at": _iso(game.imported_at),
                "updated_at": _iso(game.updated_at),
            }
            for game in games
        ],
        "versions": [
            {
                "game_key": game_keys.get(version.game_id),
                "game": None,
                "platform": version.platform or SYSTEM_CATEGORY_NAME,
                "filename": version.filename,
                "file_path": version.file_path,
                "source_type": version.source_type,
                "source_key": source_keys.get(version.source_id),
                "source_path": version.source_path,
                "file_size": version.file_size or 0,
                "extract_password": version.extract_password,
                "checksum_algo": version.checksum_algo,
                "checksum": version.checksum,
                "checksum_updated_at": _iso(version.checksum_updated_at),
            }
            for version in versions
        ],
        "tags": [{"name": tag.name, "color": tag.color} for tag in tags],
        "game_tags": [
            {
                "game_key": game_keys.get(row.game_id),
                "tag": tag_names.get(row.tag_id),
                "source": row.source,
                "weight": row.weight or 0.0,
                "is_spoiler": bool(row.is_spoiler),
            }
            for row in game_tags
        ],
        "ignore_list": [
            {"path": item.path, "deleted_at": _iso(item.deleted_at)} for item in ignored
        ],
    }


async def _export_platform_categories(session) -> list[dict[str, Any]]:
    result = await session.execute(
        select(PlatformCategory)
        .options(selectinload(PlatformCategory.rules))
        .order_by(
            PlatformCategory.is_system,
            PlatformCategory.sort_order,
            PlatformCategory.id,
        )
    )
    return [
        {
            "name": category.name,
            "sort_order": category.sort_order,
            "is_system": bool(category.is_system),
            "rules": [
                {
                    "kind": rule.kind,
                    "pattern": rule.pattern,
                    "sort_order": rule.sort_order,
                }
                for rule in sorted(
                    category.rules, key=lambda item: (item.sort_order, item.id)
                )
            ],
        }
        for category in result.scalars().all()
    ]


async def _export_steam_patch(session, config) -> dict[str, Any]:
    steam_patch: dict[str, Any] = {"rules": [], "roots": []}
    source_rows = list((await session.execute(select(FileSource))).scalars())
    source_keys = {source.id: f"src-{index}" for index, source in enumerate(
        sorted(source_rows, key=lambda item: item.id), 1
    )}

    index_path = patch_rules.patch_index_path(config)
    if index_path.is_file():
        index_data = patch_rules.load_patch_index(index_path)
        steam_patch["rules"] = patch_rules.rule_entries(
            index_data["patches"], source_keys=source_keys
        )
    keywords, _ = patch_rules.read_keywords(patch_rules.keywords_path(config))
    if keywords:
        steam_patch["keywords"] = keywords

    roots = list(
        (await session.execute(select(SteamPatchRoot).order_by(SteamPatchRoot.id))).scalars()
    )
    steam_patch["roots"] = [
        {
            "path": root.path,
            "source_type": root.source_type,
            "source_key": source_keys.get(root.source_id),
            "source_name": root.source_name,
            "analysis_mode": root.analysis_mode,
        }
        for root in roots
    ]
    return steam_patch


async def _export_accounts(session) -> dict[str, list[dict[str, Any]]]:
    users = list((await session.execute(select(User).order_by(User.id))).scalars())
    return {
        "users": [
            {
                "username": user.username,
                "password_hash": user.password_hash,
                "salt": user.salt,
                "role": user.role,
                "is_admin": bool(user.is_admin),
                "status": user.status,
                "avatar": _basename(user.avatar_path),
                "created_at": _iso(user.created_at),
                "oauth_provider": user.oauth_provider,
                "oauth_subject": user.oauth_subject,
                "oauth_name": user.oauth_name,
                "oauth_user_id": user.oauth_user_id,
                "password_set": bool(user.password_set),
            }
            for user in users
        ]
    }


def _safe_decrypt(value: str | None) -> str:
    """Decrypt a stored credential; a broken value is exported as empty text."""
    try:
        return decrypt_secret(value)
    except Exception:
        echo("警告: 有一项凭据无法解密，导出结果中该字段为空")
        return ""


def _export_settings(config) -> dict[str, Any]:
    """Collect persisted app settings (scan + scraper, credentials decrypted)."""
    settings: dict[str, Any] = {}
    data_dir = Path(config.data_path)
    scan_path = data_dir / "scan_settings.json"
    if scan_path.is_file():
        try:
            settings["scan"] = json.loads(scan_path.read_text(encoding="utf-8"))
        except Exception:
            echo("警告: 扫描设置无法读取，已跳过")
    scraper_path = data_dir / "scraper_config.json"
    if scraper_path.is_file():
        try:
            data = json.loads(scraper_path.read_text(encoding="utf-8"))
        except Exception:
            data = {}
        if isinstance(data, dict) and data:
            for key in SCRAPER_SECRET_KEYS:
                value = data.get(key)
                if isinstance(value, str) and value:
                    data[key] = _safe_decrypt(value)
            settings["scraper"] = data
    custom_regex = getattr(config, "custom_regex", None) or []
    if custom_regex:
        settings["custom_regex"] = [
            {
                "pattern": item.pattern,
                "platform": item.platform,
                "description": item.description,
            }
            for item in custom_regex
        ]
    return settings


async def build_payload(config, scope: str = SCOPE_ALL) -> dict[str, Any]:
    """Collect the backup payload; `scope` limits it to patch rules or the library."""
    if scope not in EXPORT_SCOPES:
        raise ValueError(f"unknown backup scope: {scope}")

    payload: dict[str, Any] = {
        "kind": KIND,
        "schema_version": SCHEMA_VERSION,
        "app": "Sena-Repo",
        "exported_at": utc_iso(),
        "source": {
            "data_path": str(config.data_path),
            "patch_index": str(patch_rules.patch_index_path(config)),
            "keywords": str(patch_rules.keywords_path(config)),
        },
        "scope": scope,
        "steam_patch": {},
        "library": {},
        "accounts": {},
        "settings": {},
        "media": {kind: [] for kind in MEDIA_KINDS},
    }

    async with db._session_factory() as session:
        if scope in (SCOPE_ALL, SCOPE_LIBRARY):
            library = await _export_library(session)
            library["platform_categories"] = await _export_platform_categories(session)
            payload["accounts"] = await _export_accounts(session)
        else:
            # Patch-only archives still need the file sources their roots point at.
            library = {"file_sources": await _export_file_sources(session)}
        payload["library"] = library
        if scope in (SCOPE_ALL, SCOPE_PATCH):
            payload["steam_patch"] = await _export_steam_patch(session, config)
    if scope in (SCOPE_ALL, SCOPE_LIBRARY):
        payload["settings"] = _export_settings(config)

    return payload


def _media_key(path: Path) -> str:
    """Content-addressed name: identical images dedupe, different ones never clash."""
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return f"{digest.hexdigest()[:24]}{path.suffix.lower()}"


def collect_media(config, payload: dict[str, Any]) -> dict[str, dict[str, Path]]:
    """Map media references to content keys and record which files to archive."""
    directories = media_dirs(config)
    libraries: dict[str, dict[str, Path]] = {kind: {} for kind in MEDIA_KINDS}
    cache: dict[str, dict[str, str | None]] = {kind: {} for kind in MEDIA_KINDS}

    def resolve(kind: str, value: Any) -> str | None:
        name = _basename(value)
        if not name:
            return None
        if name in cache[kind]:
            return cache[kind][name]
        path = directories[kind] / name
        if not path.is_file():
            cache[kind][name] = None
            return None
        key = _media_key(path)
        cache[kind][name] = key
        libraries[kind][key] = path
        return key

    for game in (payload.get("library") or {}).get("games") or []:
        game["cover"] = resolve("covers", game.get("cover"))
        game["background"] = resolve("backgrounds", game.get("background"))
    for user in (payload.get("accounts") or {}).get("users") or []:
        user["avatar"] = resolve("avatars", user.get("avatar"))

    payload["media"] = {
        kind: [
            {"key": key, "name": path.name, "size": path.stat().st_size}
            for key, path in sorted(libraries[kind].items())
        ]
        for kind in MEDIA_KINDS
    }
    return libraries


def write_backup(output: Path, payload: dict[str, Any], media: dict[str, dict[str, Path]],
                 *, include_media: bool) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    if not include_media:
        patch_rules.write_json(output, payload)
        return
    tmp_path = output.with_name(f".{output.name}.{secrets.token_hex(3)}.tmp")
    with zipfile.ZipFile(tmp_path, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr(JSON_NAME, json.dumps(payload, ensure_ascii=False, indent=2) + "\n")
        for kind, files in media.items():
            for key, path in files.items():
                archive.write(path, f"media/{kind}/{key}", compress_type=zipfile.ZIP_STORED)
    tmp_path.replace(output)


async def cmd_backup(args) -> int:
    config = await prepare_app()
    json_only = bool(getattr(args, "json_only", False))
    scope = getattr(args, "scope", SCOPE_ALL) or SCOPE_ALL
    if scope not in EXPORT_SCOPES:
        fail(f"不支持的备份范围: {scope}", 2)
    include_media = (not json_only) and scope != SCOPE_PATCH
    output = resolve_output(args, config, ".zip" if include_media else ".json", scope)

    payload = await build_payload(config, scope=scope)
    media = collect_media(config, payload)
    await asyncio.to_thread(
        write_backup, output, payload, media, include_media=include_media
    )

    library = payload["library"]
    echo(f"已导出备份: {output}")
    echo(f"范围: {scope}")
    echo(f"补丁规则: {len(payload['steam_patch'].get('rules') or [])} 条"
         + ("，含类型关键词" if payload["steam_patch"].get("keywords") else ""))
    echo(f"游戏库: {len(library.get('games') or [])} 个游戏 / "
         f"{len(library.get('versions') or [])} 个版本 / {len(library.get('tags') or [])} 个标签")
    echo(f"账号: {len(payload['accounts'].get('users') or [])} 个")
    if not include_media:
        echo("媒体: 未包含（--json-only）")
    else:
        echo(f"媒体: {sum(len(files) for files in media.values())} 个文件")
    echo("提示: 备份包含账号密码哈希与解压密码，请妥善保管。")
    return 0


# ── automatic backups ──

_auto_running = False


def auto_backup_running() -> bool:
    return _auto_running


def auto_backup_name(suffix: str, scope: str) -> str:
    return f"auto-sena-backup-{utc_timestamp()}-{scope}-{secrets.token_hex(3)}{suffix}"


def is_auto_backup(path: Path) -> bool:
    return (
        path.is_file()
        and path.name.startswith("auto-sena-backup-")
        and path.suffix.lower() in {".zip", ".json"}
    )


def list_auto_backups(config) -> list[Path]:
    root = backup_dir(config)
    if not root.is_dir():
        return []
    files = [path for path in root.iterdir() if is_auto_backup(path)]
    return sorted(files, key=lambda item: item.stat().st_mtime, reverse=True)


def prune_auto_backups(config, retention: dict[str, int]) -> list[str]:
    """Grandfather-father-son cleanup; only files this feature created."""
    files = list_auto_backups(config)
    if not files:
        return []
    keep: set[Path] = set()
    last = int(retention.get("last") or 0)
    if last > 0:
        keep.update(files[:last])

    now = datetime.now()
    buckets = (
        (
            int(retention.get("daily") or 0),
            lambda stamp: stamp.strftime("%Y-%m-%d"),
            lambda stamp: (now.date() - stamp.date()).days,
        ),
        (
            int(retention.get("weekly") or 0),
            lambda stamp: stamp.strftime("%G-%V"),
            lambda stamp: max(0, (now.date() - stamp.date()).days) // 7,
        ),
        (
            int(retention.get("monthly") or 0),
            lambda stamp: stamp.strftime("%Y-%m"),
            lambda stamp: (now.year - stamp.year) * 12 + (now.month - stamp.month),
        ),
    )
    for limit, bucket_key, bucket_age in buckets:
        if limit <= 0:
            continue
        seen: set[str] = set()
        for path in files:
            stamp = datetime.fromtimestamp(path.stat().st_mtime)
            if bucket_age(stamp) >= limit:
                continue
            key = bucket_key(stamp)
            if key in seen:
                continue
            seen.add(key)
            keep.add(path)

    removed: list[str] = []
    for path in files:
        if path in keep:
            continue
        try:
            path.unlink()
            removed.append(path.name)
        except OSError as exc:
            logger.warning(
                "Auto backup cleanup failed: file=%s error=%s",
                path.name,
                type(exc).__name__,
            )
            continue
    return removed


async def backup_fingerprint(config) -> str:
    """Cheap change stamp: row counts, newest timestamps and data-file mtimes."""
    async with db._session_factory() as session:
        counts: dict[str, int] = {}
        for key, model in (
            ("games", Game),
            ("versions", GameVersion),
            ("users", User),
            ("tags", Tag),
            ("game_tags", GameTag),
            ("roots", RootDirectory),
            ("sources", FileSource),
            ("ignored", IgnoreList),
            ("categories", PlatformCategory),
        ):
            total = (
                await session.execute(select(func.count()).select_from(model))
            ).scalar()
            counts[key] = int(total or 0)
        latest_game = (await session.execute(select(func.max(Game.updated_at)))).scalar()
        latest_version = (
            await session.execute(select(func.max(GameVersion.checksum_updated_at)))
        ).scalar()

    data_dir = Path(config.data_path or "/data")
    stamps: list[int] = []
    for path in (
        patch_rules.patch_index_path(config),
        patch_rules.keywords_path(config),
        data_dir / "scan_settings.json",
        data_dir / "scraper_config.json",
        Path(config.covers_path),
        Path(config.backgrounds_path),
        data_dir / "avatars",
    ):
        try:
            stamps.append(int(path.stat().st_mtime_ns))
        except OSError:
            stamps.append(0)
    payload = [sorted(counts.items()), str(latest_game), str(latest_version), stamps]
    return hashlib.sha256(json.dumps(payload).encode("utf-8")).hexdigest()


async def run_auto_backup(config) -> dict[str, Any]:
    """Create one automatic backup, honouring the guards and retention policy."""
    global _auto_running
    from services import backup_schedule as sched

    settings = sched.load_backup_settings(config)
    started = datetime.now()
    lock_path = Path(config.data_path or "/data") / ".restore.lock"

    _auto_running = True
    try:
        with ExitStack() as stack:
            acquired = stack.enter_context(process_lock(lock_path, blocking=False))
            scan_idle = stack.enter_context(
                process_lock(scan_lock_path(config.data_path), blocking=False)
            )
            if not acquired or not scan_idle:
                sched.save_backup_settings(
                    config,
                    sched.record_skip(
                        settings, now=started, reason="busy", delay_minutes=5
                    ),
                )
                return {"skipped": "busy"}

            min_free = float(settings.get("min_free_gb") or 0)
            if min_free > 0:
                free = shutil.disk_usage(Path(config.data_path or "/data")).free
                if free < min_free * 1024 ** 3:
                    message = f"磁盘余量不足：{free / 1024 ** 3:.1f} GB"
                    sched.save_backup_settings(
                        config,
                        sched.record_failure(settings, now=started, message=message),
                    )
                    return {"skipped": "low-space", "error": message}

            fingerprint = await backup_fingerprint(config)
            if settings.get("skip_if_unchanged") and fingerprint == settings.get(
                "last_fingerprint"
            ):
                sched.save_backup_settings(
                    config,
                    sched.record_skip(
                        settings,
                        now=started,
                        reason="unchanged",
                        fingerprint=fingerprint,
                    ),
                )
                return {"skipped": "unchanged"}

            scope = str(settings.get("scope") or SCOPE_ALL)
            include_media = bool(settings.get("include_media")) and scope != SCOPE_PATCH
            suffix = ".zip" if include_media else ".json"
            output = backup_dir(config) / auto_backup_name(suffix, scope)
            payload = await build_payload(config, scope=scope)
            media = collect_media(config, payload)
            await asyncio.to_thread(
                write_backup, output, payload, media, include_media=include_media
            )
            removed = await asyncio.to_thread(
                prune_auto_backups, config, settings.get("retention") or {}
            )
            sched.save_backup_settings(
                config,
                sched.record_success(
                    settings,
                    now=started,
                    file_name=output.name,
                    fingerprint=fingerprint,
                ),
            )
            return {
                "file": output.name,
                "bytes": output.stat().st_size,
                "removed": removed,
                "games": len(payload["library"].get("games") or []),
            }
    finally:
        _auto_running = False


# ── payload loading ──


def read_backup_payload(path: Path) -> dict[str, Any]:
    if not path.is_file():
        fail(f"文件不存在: {path}", 3)
    try:
        if zipfile.is_zipfile(path):
            with zipfile.ZipFile(path) as archive:
                if JSON_NAME not in archive.namelist():
                    fail(f"备份文件缺少 {JSON_NAME}", 3)
                raw = archive.read(JSON_NAME).decode("utf-8")
        else:
            raw = path.read_text(encoding="utf-8")
    except OSError as exc:
        fail(f"读取备份失败: {exc}", 3)
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as exc:
        fail(f"备份文件格式错误: {exc}", 3)
    if not isinstance(data, dict):
        fail("备份文件顶层必须是对象", 3)
    if data.get("kind") != KIND:
        fail("备份文件类型不正确，不是 Sena-Repo 备份", 3)
    if data.get("schema_version") != SCHEMA_VERSION:
        fail(
            f"备份格式版本 {data.get('schema_version')} 已不再支持，"
            "请用当前版本的 senacli backup 重新导出",
            3,
        )
    return data


def _expect_list(value: Any, label: str) -> list[Any]:
    if not isinstance(value, list):
        fail(f"备份结构不正确: {label} 必须是数组", 3)
    return value


def _expect_dict(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        fail(f"备份结构不正确: {label} 必须是对象", 3)
    return value


def _require(entry: dict[str, Any], key: str, label: str) -> Any:
    value = entry.get(key)
    if value in (None, ""):
        fail(f"备份结构不正确: {label} 缺少 {key}", 3)
    return value


def normalise_payload(data: dict[str, Any]) -> dict[str, Any]:
    """Validate the archive structure and cross-references before touching data."""
    library = _expect_dict(data.get("library") or {}, "library")
    accounts = _expect_dict(data.get("accounts") or {}, "accounts")
    settings = _expect_dict(data.get("settings") or {}, "settings")
    steam_patch = _expect_dict(data.get("steam_patch") or {}, "steam_patch")
    media_raw = _expect_dict(data.get("media") or {}, "media")

    sources = _expect_list(library.get("file_sources") or [], "library.file_sources")
    source_keys: set[str] = set()
    for entry in sources:
        entry = _expect_dict(entry, "library.file_sources[]")
        key = _require(entry, "key", "文件源")
        if key in source_keys:
            fail(f"备份结构不正确: 文件源标识 {key} 重复", 3)
        source_keys.add(key)

    roots = _expect_list(library.get("roots") or [], "library.roots")
    root_keys: set[str] = set()
    for entry in roots:
        entry = _expect_dict(entry, "library.roots[]")
        key = _require(entry, "key", "目录库")
        if key in root_keys:
            fail(f"备份结构不正确: 目录库标识 {key} 重复", 3)
        root_keys.add(key)
        if str(entry.get("source_type") or "local") == "openlist":
            source_key = entry.get("source_key")
            if not source_key or source_key not in source_keys:
                fail(
                    f"备份结构不正确: 目录库 {entry.get('path')} 引用了缺失的文件源",
                    3,
                )

    media: dict[str, dict[str, dict[str, Any]]] = {}
    for kind in MEDIA_KINDS:
        entries = _expect_list(media_raw.get(kind) or [], f"media.{kind}")
        known: dict[str, dict[str, Any]] = {}
        for entry in entries:
            entry = _expect_dict(entry, f"media.{kind}[]")
            key = _require(entry, "key", f"媒体 {kind}")
            if not MEDIA_KEY_RE.match(str(key)):
                fail(f"备份结构不正确: 媒体标识不合法: {key}", 3)
            known[key] = entry
        media[kind] = known

    games = _expect_list(library.get("games") or [], "library.games")
    game_keys: set[str] = set()
    for entry in games:
        entry = _expect_dict(entry, "library.games[]")
        key = _require(entry, "key", "游戏")
        if key in game_keys:
            fail(f"备份结构不正确: 游戏标识 {key} 重复", 3)
        game_keys.add(key)
        entry_source = str(entry.get("entry_source") or "library")
        if entry_source not in ENTRY_SOURCES:
            fail(f"备份结构不正确: 未知的条目标识 {entry_source}", 3)
        if entry_source == "library" and entry.get("root_key") not in root_keys:
            fail(f"备份结构不正确: 游戏 {entry.get('name')} 引用了缺失的目录库", 3)
        for field, kind in (("cover", "covers"), ("background", "backgrounds")):
            value = entry.get(field)
            if value and value not in media[kind]:
                fail(f"备份结构不正确: 游戏 {entry.get('name')} 的图片不在媒体清单中", 3)

    versions = _expect_list(library.get("versions") or [], "library.versions")
    for entry in versions:
        entry = _expect_dict(entry, "library.versions[]")
        if entry.get("game_key") not in game_keys:
            fail("备份结构不正确: 版本引用了缺失的游戏", 3)
        if entry.get("source_key") and entry["source_key"] not in source_keys:
            fail("备份结构不正确: 版本引用了缺失的文件源", 3)

    for entry in _expect_list(library.get("game_tags") or [], "library.game_tags"):
        entry = _expect_dict(entry, "library.game_tags[]")
        if entry.get("game_key") not in game_keys:
            fail("备份结构不正确: 标签关联引用了缺失的游戏", 3)

    for entry in _expect_list(accounts.get("users") or [], "accounts.users"):
        entry = _expect_dict(entry, "accounts.users[]")
        _require(entry, "username", "账号")
        avatar = entry.get("avatar")
        if avatar and avatar not in media["avatars"]:
            fail(f"备份结构不正确: 账号 {entry.get('username')} 的头像不在媒体清单中", 3)

    rules = _expect_list(steam_patch.get("rules") or [], "steam_patch.rules")
    for entry in rules:
        entry = _expect_dict(entry, "steam_patch.rules[]")
        if not isinstance(entry.get("identity"), dict) or not isinstance(entry.get("rule"), dict):
            fail("备份结构不正确: 补丁规则缺少 identity 或 rule", 3)

    patch_roots = _expect_list(steam_patch.get("roots") or [], "steam_patch.roots")
    for entry in patch_roots:
        entry = _expect_dict(entry, "steam_patch.roots[]")
        _require(entry, "path", "补丁库目录")
        source_key = entry.get("source_key")
        if str(entry.get("source_type") or "local") == "openlist":
            if not source_key or source_key not in source_keys:
                fail(f"备份结构不正确: 补丁库目录 {entry.get('path')} 引用了缺失的文件源", 3)

    return {
        "rules": rules,
        "keywords": patch_rules.normalise_keywords(steam_patch.get("keywords")),
        "patch_roots": patch_roots,
        "library": library,
        "settings": settings,
        "accounts": accounts,
        "media": media,
    }


# ── import helpers ──


def _platform_name(value: Any) -> str:
    name = str(value or "").strip()
    return name or SYSTEM_CATEGORY_NAME


async def import_file_sources(
    session,
    entries: list[dict[str, Any]],
    *,
    replace: bool,
) -> tuple[dict[str, int], dict[str, int], list[str]]:
    """Restore file sources and return a backup-key → local-id map."""
    stats = {"sources_new": 0, "sources_updated": 0}
    notes: list[str] = []
    entries = [
        entry
        for entry in entries
        if str(entry.get("name") or "").strip() and str(entry.get("key") or "").strip()
    ]
    backup_name_counts: dict[str, int] = {}
    for entry in entries:
        name = str(entry["name"]).strip()
        backup_name_counts[name] = backup_name_counts.get(name, 0) + 1

    existing: dict[str, list[FileSource]] = {}
    for source in (await session.execute(select(FileSource))).scalars():
        if source.name:
            existing.setdefault(source.name, []).append(source)
    by_key: dict[str, int] = {}

    for entry in entries:
        name = str(entry.get("name")).strip()
        key = str(entry.get("key")).strip()
        fields: dict[str, Any] = {
            "type": str(entry.get("type") or "local"),
            "base_url": entry.get("base_url"),
            "username": entry.get("username"),
            "enabled": bool(entry.get("enabled", True)),
        }
        password = entry.get("password")
        if isinstance(password, str) and password:
            fields["password"] = encrypt_secret(password)

        candidates = existing.get(name, [])
        source = None
        if len(candidates) == 1 and backup_name_counts[name] == 1:
            source = candidates[0]
        elif candidates:
            # Duplicate names exist on one side; pair them by address instead.
            source = next(
                (
                    item
                    for item in candidates
                    if (item.base_url or "") == (fields.get("base_url") or "")
                ),
                None,
            )
            if source is None and backup_name_counts[name] == 1:
                source = candidates[0]

        if source is None:
            source = FileSource(name=name, **fields)
            session.add(source)
            await session.flush()
            existing.setdefault(name, []).append(source)
            stats["sources_new"] += 1
            if backup_name_counts[name] > 1 or len(existing[name]) > 1:
                notes.append(
                    f"文件源「{name}」存在多个同名配置，"
                    f"已按地址 {fields.get('base_url') or '（空）'} 单独创建"
                )
            else:
                notes.append(f"已创建文件源「{name}」")
        elif replace:
            for field_name, value in fields.items():
                setattr(source, field_name, value)
            stats["sources_updated"] += 1
        else:
            if (source.base_url or "") != (fields.get("base_url") or ""):
                notes.append(
                    f"文件源「{name}」与本机地址不同，已保留本机配置"
                )
            else:
                notes.append(f"文件源「{name}」已存在，保留本机配置")
        by_key[key] = source.id

    return stats, by_key, notes


async def import_platform_categories(
    session, entries: list[dict[str, Any]], *, replace: bool
) -> tuple[dict[str, int], list[str]]:
    stats = {"categories_new": 0, "categories_updated": 0, "rules_new": 0}
    notes: list[str] = []
    if not entries:
        return stats, notes

    if replace:
        await session.execute(
            delete(PlatformCategoryRule).where(
                PlatformCategoryRule.category_id.in_(
                    select(PlatformCategory.id).where(PlatformCategory.is_system == False)  # noqa: E712
                )
            )
        )
        await session.execute(
            delete(PlatformCategory).where(PlatformCategory.is_system == False)  # noqa: E712
        )
        await session.flush()

    existing = {
        category.name: category
        for category in (await session.execute(select(PlatformCategory))).scalars()
    }

    for entry in entries:
        if not isinstance(entry, dict):
            continue
        name = str(entry.get("name") or "").strip()
        if not name or name == SYSTEM_CATEGORY_NAME:
            continue
        category = existing.get(name)
        sort_order = int(entry.get("sort_order") or 0)
        created = category is None
        previous_order = None if created else category.sort_order
        if created:
            category = await ensure_category(session, name)
            existing[name] = category
            stats["categories_new"] += 1
        category.sort_order = sort_order
        rules_added = 0

        rules = entry.get("rules")
        if not isinstance(rules, list) or not rules or category.is_system:
            if not created and previous_order != sort_order:
                stats["categories_updated"] += 1
            continue
        known = {
            (rule.kind, rule.pattern)
            for rule in (
                await session.execute(
                    select(PlatformCategoryRule).where(
                        PlatformCategoryRule.category_id == category.id
                    )
                )
            ).scalars()
        }
        for rule_entry in rules:
            if not isinstance(rule_entry, dict):
                continue
            kind = str(rule_entry.get("kind") or "").strip().lower()
            pattern = str(rule_entry.get("pattern") or "").strip()
            if kind not in ("keyword", "regex") or not pattern:
                continue
            if (kind, pattern) in known:
                continue
            session.add(
                PlatformCategoryRule(
                    category_id=category.id,
                    kind=kind,
                    pattern=pattern,
                    sort_order=int(rule_entry.get("sort_order") or len(known)),
                )
            )
            known.add((kind, pattern))
            stats["rules_new"] += 1
            rules_added += 1
        if not created and (previous_order != sort_order or rules_added):
            stats["categories_updated"] += 1
    await session.flush()
    if stats["categories_new"] or stats["categories_updated"] or stats["rules_new"]:
        notes.append(
            "分类: 新增 {categories_new} / 更新 {categories_updated} 个分类、"
            "{rules_new} 条匹配规则".format(**stats)
        )
    return stats, notes


async def import_library(
    config,
    session,
    library: dict[str, Any],
    *,
    replace: bool,
    source_map: dict[str, int],
    available_media: dict[str, set[str]],
    overwrite_media: bool,
) -> tuple[dict[str, int], list[str]]:
    stats = {
        "roots_new": 0, "roots_matched": 0, "roots_skipped": 0,
        "games_new": 0, "games_updated": 0, "games_skipped": 0,
        "versions_new": 0, "versions_updated": 0,
        "tags_new": 0, "tags_updated": 0, "game_tags": 0,
        "companies_new": 0, "ignored_new": 0,
        "categories_new": 0, "categories_updated": 0, "rules_new": 0,
        "media_skipped": 0,
    }
    notes: list[str] = []

    category_stats, category_notes = await import_platform_categories(
        session, library.get("platform_categories") or [], replace=replace
    )
    stats.update(category_stats)
    notes.extend(category_notes)
    known_categories = {
        category.name
        for category in (await session.execute(select(PlatformCategory))).scalars()
    }

    existing_roots = {
        root.path: root for root in (await session.execute(select(RootDirectory))).scalars()
    }
    root_by_key: dict[str, RootDirectory] = {}
    prefix_map: list[tuple[str, str]] = []

    for entry in library.get("roots") or []:
        key = str(entry.get("key") or "").strip()
        old_path = str(entry.get("path") or "").strip()
        if not key or not old_path:
            continue
        source_type = str(entry.get("source_type") or "local")
        source_id = None
        source_name = entry.get("source_name")
        if source_type == "openlist":
            source_key = entry.get("source_key")
            source_id = source_map.get(str(source_key)) if source_key else None
            if source_id is None:
                stats["roots_skipped"] += 1
                notes.append(
                    f"缺少 OpenList 文件源「{source_name or source_key}」，"
                    f"已跳过目录库 {old_path}"
                )
                continue
            source_name = entry.get("source_name") or source_name
        new_path = canonical_source_path(
            source_type, source_id, entry.get("source_path") or old_path
        )
        root = existing_roots.get(new_path)
        if root is None:
            root = RootDirectory(
                path=new_path,
                source_type=source_type,
                source_id=source_id,
                source_name=source_name,
                source_path=entry.get("source_path"),
                enable_batch_scrape=bool(entry.get("enable_batch_scrape", True)),
            )
            session.add(root)
            await session.flush()
            existing_roots[new_path] = root
            stats["roots_new"] += 1
        else:
            root.source_type = source_type
            root.source_id = source_id
            root.source_name = source_name
            root.source_path = entry.get("source_path")
            root.enable_batch_scrape = bool(entry.get("enable_batch_scrape", True))
            stats["roots_matched"] += 1
        root_by_key[key] = root
        if new_path != old_path:
            prefix_map.append((old_path, new_path))

    def remap(value: Any) -> str:
        text = str(value or "")
        for old, new in sorted(prefix_map, key=lambda item: len(item[0]), reverse=True):
            if text == old:
                return new
            if text.startswith(old + "/"):
                return new + text[len(old):]
        return text

    companies = {c.name: c for c in (await session.execute(select(Company))).scalars()}
    for entry in library.get("companies") or []:
        name = str(entry.get("name") or "").strip()
        if not name or name in companies:
            continue
        company = Company(name=name)
        created_at = _parse_dt(entry.get("created_at"))
        if created_at is not None:
            company.created_at = created_at
        session.add(company)
        await session.flush()
        companies[name] = company
        stats["companies_new"] += 1
    games_by_path = {
        game.folder_path: game for game in (await session.execute(select(Game))).scalars()
    }
    directories = media_dirs(config)
    game_ids: dict[str, int] = {}
    locked_game_ids: set[int] = set()

    for entry in library.get("games") or []:
        key = str(entry.get("key") or "").strip()
        old_folder = str(entry.get("folder_path") or "").strip()
        if not key or not old_folder:
            continue
        entry_source = str(entry.get("entry_source") or "library")
        root = root_by_key.get(str(entry.get("root_key") or ""))
        if root is None:
            if entry_source in ("manual", "metadata"):
                # Virtual entries carry no directory library; the API stores root_id 0.
                root_id = 0
            else:
                stats["games_skipped"] += 1
                notes.append(f"缺少目录库，已跳过游戏 {entry.get('name') or old_folder}")
                continue
        else:
            root_id = root.id

        company = None
        company_name = entry.get("company")
        if company_name:
            company = companies.get(company_name)
            if company is None:
                company = Company(name=company_name)
                session.add(company)
                await session.flush()
                companies[company_name] = company
                stats["companies_new"] += 1

        folder_path = remap(old_folder)
        cover_key = entry.get("cover")
        background_key = entry.get("background")
        fields = {
            "name": entry.get("name") or _basename(folder_path) or folder_path,
            "company_id": company.id if company else None,
            "root_id": root_id,
            "folder_path": folder_path,
            "entry_source": entry_source,
            "cover_path": str(directories["covers"] / cover_key)
            if cover_key in available_media["covers"] else None,
            "bg_path": str(directories["backgrounds"] / background_key)
            if background_key in available_media["backgrounds"] else None,
            "is_nsfw": bool(entry.get("is_nsfw", False)),
            "developer": entry.get("developer"),
            "alias": entry.get("alias"),
            "description": entry.get("description"),
            "release_date": entry.get("release_date"),
            "vndb_id": entry.get("vndb_id"),
            "steam_id": entry.get("steam_id"),
            "bangumi_id": entry.get("bangumi_id"),
            "hikarinagi_id": entry.get("hikarinagi_id"),
            "nextmoe_id": entry.get("nextmoe_id"),
            "length": entry.get("length") or 0,
            "length_minutes": entry.get("length_minutes") or 0,
            "metadata_locked": bool(entry.get("metadata_locked", False)),
            "name_locked": bool(entry.get("name_locked", False)),
            "is_deleted": bool(entry.get("is_deleted", False)),
        }
        game = games_by_path.get(folder_path)
        if game is None:
            game = Game(**fields)
            imported_at = _parse_dt(entry.get("imported_at"))
            if imported_at is not None:
                game.imported_at = imported_at
            session.add(game)
            await session.flush()
            games_by_path[folder_path] = game
            stats["games_new"] += 1
        elif game.metadata_locked:
            # Keep local metadata of locked games; never unlock on restore.
            locked_game_ids.add(game.id)
            stats["games_skipped"] += 1
            notes.append(f"游戏「{game.name}」已锁定，已保留本机元数据")
        else:
            if game.name_locked:
                fields.pop("name", None)
                fields.pop("company_id", None)
                fields["name_locked"] = True
            if not overwrite_media:
                if game.cover_path:
                    fields.pop("cover_path", None)
                if game.bg_path:
                    fields.pop("bg_path", None)
                if game.cover_path or game.bg_path:
                    stats["media_skipped"] += 1
            for field_name, value in fields.items():
                setattr(game, field_name, value)
            stats["games_updated"] += 1
        updated_at = _parse_dt(entry.get("updated_at"))
        if updated_at is not None:
            game.updated_at = updated_at
        game_ids[key] = game.id

    versions = {
        (version.game_id, version.file_path): version
        for version in (await session.execute(select(GameVersion))).scalars()
    }
    for entry in library.get("versions") or []:
        game_id = game_ids.get(str(entry.get("game_key") or ""))
        if game_id is None:
            continue
        file_path = remap(entry.get("file_path"))
        if not file_path:
            continue
        source_key = entry.get("source_key")
        source_id = source_map.get(str(source_key)) if source_key else None
        platform = _platform_name(entry.get("platform"))
        if platform not in known_categories:
            await ensure_category(session, platform)
            known_categories.add(platform)
        data = {
            "game_id": game_id,
            "platform": platform,
            "filename": entry.get("filename") or _basename(file_path) or file_path,
            "file_path": file_path,
            "source_type": entry.get("source_type") or "local",
            "source_id": source_id,
            "source_path": remap(entry.get("source_path")) or None,
            "file_size": entry.get("file_size") or 0,
            "extract_password": entry.get("extract_password"),
            "checksum_algo": entry.get("checksum_algo"),
            "checksum": entry.get("checksum"),
            "checksum_updated_at": _parse_dt(entry.get("checksum_updated_at")),
        }
        version = versions.get((game_id, file_path))
        if version is None:
            session.add(GameVersion(**data))
            stats["versions_new"] += 1
        else:
            for field_name, value in data.items():
                setattr(version, field_name, value)
            stats["versions_updated"] += 1

    tags = {tag.name: tag for tag in (await session.execute(select(Tag))).scalars()}
    for entry in library.get("tags") or []:
        name = str(entry.get("name") or "").strip()
        if not name:
            continue
        tag = tags.get(name)
        if tag is None:
            tag = Tag(name=name, color=entry.get("color") or "#3B82F6")
            session.add(tag)
            await session.flush()
            tags[name] = tag
            stats["tags_new"] += 1
        elif entry.get("color"):
            tag.color = entry["color"]
            stats["tags_updated"] += 1

    associations = {
        (row.game_id, row.tag_id): row
        for row in (await session.execute(select(GameTag))).scalars()
    }
    for entry in library.get("game_tags") or []:
        game_id = game_ids.get(str(entry.get("game_key") or ""))
        tag = tags.get(str(entry.get("tag") or ""))
        if game_id is None or tag is None or game_id in locked_game_ids:
            continue
        source = str(entry.get("source") or "user")
        weight = float(entry.get("weight") or 0.0)
        is_spoiler = bool(entry.get("is_spoiler", False))
        row = associations.get((game_id, tag.id))
        if row is None:
            session.add(GameTag(game_id=game_id, tag_id=tag.id, source=source,
                                weight=weight, is_spoiler=is_spoiler))
            stats["game_tags"] += 1
        else:
            row.source = source
            row.weight = weight
            row.is_spoiler = is_spoiler

    known_ignored = {
        item.path for item in (await session.execute(select(IgnoreList))).scalars()
    }
    for entry in library.get("ignore_list") or []:
        path = remap(entry.get("path"))
        if not path or path in known_ignored:
            continue
        item = IgnoreList(path=path)
        deleted_at = _parse_dt(entry.get("deleted_at"))
        if deleted_at is not None:
            item.deleted_at = deleted_at
        session.add(item)
        known_ignored.add(path)
        stats["ignored_new"] += 1

    return stats, notes


async def import_patch_roots(
    session,
    entries: list[dict[str, Any]],
    source_map: dict[str, int],
) -> tuple[dict[str, int], list[str]]:
    stats = {"patch_roots_new": 0, "patch_roots_matched": 0, "patch_roots_skipped": 0}
    notes: list[str] = []
    if not entries:
        return stats, notes

    existing = {
        (root.source_type, root.source_id, root.path): root
        for root in (await session.execute(select(SteamPatchRoot))).scalars()
    }
    for entry in entries:
        path = str(entry.get("path") or "").strip()
        if not path:
            stats["patch_roots_skipped"] += 1
            continue
        source_type = str(entry.get("source_type") or "local")
        source_id = None
        source_name = entry.get("source_name")
        if source_type == "openlist":
            source_key = entry.get("source_key")
            source_id = source_map.get(str(source_key)) if source_key else None
            if source_id is None:
                stats["patch_roots_skipped"] += 1
                notes.append(
                    f"缺少 OpenList 文件源「{source_name or source_key}」，"
                    f"已跳过补丁库目录 {path}"
                )
                continue
        analysis_mode = str(entry.get("analysis_mode") or "auto")
        key = (source_type, source_id, path)
        root = existing.get(key)
        if root is None:
            root = SteamPatchRoot(
                path=path,
                source_type=source_type,
                source_id=source_id,
                source_name=str(source_name) if source_name else None,
                analysis_mode=analysis_mode,
            )
            session.add(root)
            existing[key] = root
            stats["patch_roots_new"] += 1
            continue
        root.source_name = str(source_name) if source_name else None
        root.analysis_mode = analysis_mode
        stats["patch_roots_matched"] += 1
    return stats, notes


async def import_accounts(
    config,
    session,
    accounts: dict[str, Any],
    *,
    available_media: dict[str, set[str]],
) -> tuple[dict[str, int], list[str]]:
    stats = {"users_new": 0, "users_updated": 0, "users_skipped": 0, "sessions_revoked": 0}
    notes: list[str] = []
    entries = accounts.get("users") or []
    if not entries:
        return stats, notes

    avatars_dir = media_dirs(config)["avatars"]
    existing = {
        user.username: user for user in (await session.execute(select(User))).scalars()
    }
    for entry in entries:
        username = str(entry.get("username") or "").strip()
        if not username:
            stats["users_skipped"] += 1
            continue
        role = str(entry.get("role") or "user")
        if role not in ("admin", "user"):
            # Older archives may still say "owner"; there is only one admin role now.
            role = "admin"
        avatar_key = entry.get("avatar")
        fields: dict[str, Any] = {
            "password_hash": entry.get("password_hash") or "",
            "salt": entry.get("salt") or "",
            "role": role,
            "is_admin": role == "admin",
            "status": str(entry.get("status") or "active"),
        }
        if avatar_key and avatar_key in available_media["avatars"]:
            fields["avatar_path"] = str(avatars_dir / avatar_key)
        for key in ("oauth_provider", "oauth_subject", "oauth_name", "oauth_user_id"):
            fields[key] = entry.get(key)
        if "password_set" in entry:
            fields["password_set"] = bool(entry.get("password_set"))

        user = existing.get(username)
        if user is None:
            user = User(username=username, **fields)
            created_at = _parse_dt(entry.get("created_at"))
            if created_at is not None:
                user.created_at = created_at
            session.add(user)
            await session.flush()
            existing[username] = user
            stats["users_new"] += 1
            continue

        password_changed = user.password_hash != fields["password_hash"]
        for field_name, value in fields.items():
            setattr(user, field_name, value)
        stats["users_updated"] += 1
        if password_changed:
            revoked = await session.execute(
                delete(UserSession).where(UserSession.user_id == user.id)
            )
            stats["sessions_revoked"] += int(revoked.rowcount or 0)

    return stats, notes


async def _ensure_admin(session) -> None:
    """Refuse to finish a restore that would leave no usable administrator."""
    admins = list(
        (await session.execute(select(User).where(User.role == "admin"))).scalars()
    )
    if not admins:
        fail("恢复后没有任何管理员账号，已取消本次恢复", 4)
    usable = any(
        admin.status == "active"
        and ((admin.password_hash or "").strip() or admin.oauth_subject)
        for admin in admins
    )
    if not usable:
        fail(
            "恢复后没有可用的管理员账号（需要启用状态，并设置密码或绑定 NextMoe），"
            "已取消本次恢复",
            4,
        )


def apply_media(
    config,
    archive: Path,
    manifest: dict[str, dict[str, Any]],
    journal: "_RestoreJournal",
) -> dict[str, set[str]]:
    """Copy archived media into place; names are content keys, so nothing is clobbered."""
    available: dict[str, set[str]] = {kind: set() for kind in MEDIA_KINDS}
    if not archive.is_file() or not zipfile.is_zipfile(archive):
        return available
    directories = media_dirs(config)
    with zipfile.ZipFile(archive) as source:
        names = set(source.namelist())
        for kind in MEDIA_KINDS:
            target_dir = directories[kind]
            for key in (manifest.get(kind) or {}):
                if not MEDIA_KEY_RE.match(str(key)):
                    continue
                entry = f"media/{kind}/{key}"
                if entry not in names:
                    continue
                available[kind].add(key)
                target_dir.mkdir(parents=True, exist_ok=True)
                destination = (target_dir / key).resolve()
                try:
                    destination.relative_to(target_dir.resolve())
                except ValueError:
                    continue
                if destination.is_file():
                    continue
                with source.open(entry) as src, open(destination, "wb") as dst:
                    shutil.copyfileobj(src, dst)
                journal.record_media(destination)
    return available


# ── restore ──


def _database_path(config) -> Path:
    url = config.database_url
    marker = "sqlite+aiosqlite:///"
    if not url.startswith(marker):
        fail("当前数据库不是 SQLite，无法创建恢复快照", 4)
    return Path(url[len(marker):])


def _snapshot_database(config, target: Path) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    source = sqlite3.connect(str(_database_path(config)))
    try:
        destination = sqlite3.connect(str(target))
        try:
            source.backup(destination)
        finally:
            destination.close()
    finally:
        source.close()


def _restore_database(config, snapshot: Path) -> None:
    """Write the snapshot back through SQLite so live connections see the old data."""
    source = sqlite3.connect(str(snapshot))
    try:
        destination = sqlite3.connect(str(_database_path(config)))
        try:
            source.backup(destination)
        finally:
            destination.close()
    finally:
        source.close()


def _write_text_atomic(path: Path, text: str, mode: int | None = None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = path.with_name(f".{path.name}.{secrets.token_hex(3)}.tmp")
    tmp_path.write_text(text, encoding="utf-8")
    if mode is not None:
        try:
            tmp_path.chmod(mode)
        except OSError:
            pass
    tmp_path.replace(path)


class _RestoreJournal:
    """Tracks everything a restore touches so a failure can be undone."""

    def __init__(self, config, snapshot: Path, journal_path: Path):
        self.config = config
        self.snapshot = snapshot
        self.journal_path = journal_path
        self.backups: dict[str, Path] = {}
        self.missing: list[Path] = []
        self.created_media: list[Path] = []

    @classmethod
    def begin(cls, config) -> "_RestoreJournal":
        safety = backup_dir(config)
        safety.mkdir(parents=True, exist_ok=True)
        stamp = f"{utc_timestamp()}-{secrets.token_hex(3)}"
        snapshot = safety / f"db-before-restore-{stamp}.sqlite3"
        journal_path = safety / "restore-in-progress.json"
        if journal_path.is_file():
            echo(
                "警告: 上一次恢复没有正常结束，安全快照保留在 "
                f"{safety}；如需回退请手动处理"
            )
        _snapshot_database(config, snapshot)
        journal = cls(config, snapshot, journal_path)
        journal.write()
        return journal

    def record_file(self, path: Path) -> None:
        if path in self.created_media:
            return
        if path.is_file():
            copy = self.snapshot.with_name(f"{self.snapshot.stem}-{path.name}")
            shutil.copy2(path, copy)
            self.backups[str(path)] = copy
        else:
            self.missing.append(path)
        self.write()

    def record_media(self, path: Path) -> None:
        self.created_media.append(path)
        self.write()

    def write(self) -> None:
        payload = {
            "started_at": utc_iso(),
            "snapshot": str(self.snapshot),
            "files": {key: str(value) for key, value in self.backups.items()},
            "missing": [str(path) for path in self.missing],
            "created_media": [str(path) for path in self.created_media],
        }
        try:
            _write_text_atomic(
                self.journal_path,
                json.dumps(payload, ensure_ascii=False, indent=2),
            )
        except OSError as exc:
            logger.warning(
                "Restore journal write failed: file=%s error=%s",
                self.journal_path.name,
                type(exc).__name__,
            )

    def rollback(self) -> list[str]:
        lines: list[str] = []
        for path in self.created_media:
            try:
                path.unlink(missing_ok=True)
            except OSError:
                lines.append(f"无法删除恢复时写入的图片: {path}")
        for key, copy in self.backups.items():
            try:
                shutil.copy2(copy, key)
            except OSError:
                lines.append(f"无法还原文件: {key}")
        for path in self.missing:
            try:
                path.unlink(missing_ok=True)
            except OSError:
                lines.append(f"无法移除恢复时新建的文件: {path}")
        try:
            _restore_database(self.config, self.snapshot)
            lines.append("数据库已回滚到恢复前状态")
        except Exception as exc:  # noqa: BLE001 - report the snapshot instead of masking
            lines.append(
                f"数据库自动回滚失败（{type(exc).__name__}），"
                f"请用 {self.snapshot} 恢复"
            )
        return lines

    def finish(self) -> None:
        try:
            self.journal_path.unlink(missing_ok=True)
        except OSError:
            pass


def _ask_scope(payload: dict[str, Any], *, yes: bool) -> str:
    has_library = _has_library_section(payload["library"]) or bool(payload["accounts"])
    has_patch = bool(
        payload["rules"] or payload["keywords"] or payload.get("patch_roots")
    )
    if not (has_patch and has_library) or yes:
        return SCOPE_ALL
    return choose(
        "恢复哪些内容？",
        [
            (SCOPE_ALL, "全部（补丁规则 + 游戏库 + 账号）"),
            (SCOPE_PATCH, "仅补丁规则"),
            (SCOPE_LIBRARY, "仅游戏库与账号"),
        ],
        default=SCOPE_ALL,
    )


def _ask_mode(*, yes: bool) -> str:
    if yes:
        return MODE_MERGE
    return choose(
        "已存在的条目怎么处理？",
        [
            (MODE_MERGE, "合并更新（按路径匹配，保留现有条目）"),
            (MODE_REPLACE, "清空重建（先删除现有游戏库、账号与忽略列表）"),
        ],
        default=MODE_MERGE,
    )


def _ask_media_policy(*, yes: bool) -> str:
    if yes:
        return MEDIA_SKIP
    return choose(
        "游戏已有封面/背景时：",
        [(MEDIA_SKIP, "保留本机已有的图片"), (MEDIA_OVERWRITE, "换成备份里的图片")],
        default=MEDIA_SKIP,
    )


def import_settings(config, settings: dict[str, Any], journal: "_RestoreJournal") -> list[str]:
    """Write scan/scraper settings back and apply them to the running config."""
    notes: list[str] = []
    if not isinstance(settings, dict) or not settings:
        return notes
    data_dir = Path(config.data_path)
    scan = settings.get("scan")
    if isinstance(scan, dict) and scan:
        path = data_dir / "scan_settings.json"
        journal.record_file(path)
        _write_text_atomic(path, json.dumps(scan, ensure_ascii=False, indent=2))
        from api.settings import _load_scan_settings

        _load_scan_settings(config)
        notes.append("扫描设置: 已恢复并生效")
    scraper = settings.get("scraper")
    if isinstance(scraper, dict) and scraper:
        payload = dict(scraper)
        for key in SCRAPER_SECRET_KEYS:
            value = payload.get(key)
            if isinstance(value, str) and value and not is_encrypted(value):
                payload[key] = encrypt_secret(value)
        path = data_dir / "scraper_config.json"
        journal.record_file(path)
        _write_text_atomic(path, json.dumps(payload, indent=2, ensure_ascii=False), mode=0o600)
        from config import reload_persisted_scraper_config

        reload_persisted_scraper_config(config)
        notes.append("刮削设置: 已恢复并生效（凭据已按本机密钥重新加密）")
    custom_regex = settings.get("custom_regex")
    if isinstance(custom_regex, list):
        if _apply_custom_regex(config, custom_regex, journal):
            notes.append("自定义分类正则: 已写入 config.yaml")
    return notes


def _config_yaml_path() -> Path:
    from cli.common import SERVER_DIR
    from config import _parse_args

    configured = Path(_parse_args().config)
    if configured.is_absolute():
        return configured
    candidate = SERVER_DIR / configured
    return candidate if candidate.is_file() else configured


def _apply_custom_regex(config, entries: list[Any], journal: "_RestoreJournal") -> bool:
    import yaml

    from config import CustomRegex

    cleaned = [
        {
            "pattern": str(item.get("pattern") or "").strip(),
            "platform": str(item.get("platform") or "").strip(),
            "description": str(item.get("description") or ""),
        }
        for item in entries
        if isinstance(item, dict) and str(item.get("pattern") or "").strip()
    ]
    path = _config_yaml_path()
    try:
        data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    except (OSError, yaml.YAMLError):
        data = {}
    if not isinstance(data, dict):
        data = {}
    data["custom_regex"] = cleaned
    journal.record_file(path)
    _write_text_atomic(path, yaml.safe_dump(data, allow_unicode=True, sort_keys=False))
    config.custom_regex = [
        CustomRegex(
            pattern=item["pattern"],
            platform=item["platform"],
            description=item["description"],
        )
        for item in cleaned
        if item["platform"].strip()
    ]
    return bool(cleaned)


async def _clear_selected(
    session, *, wants_patch: bool, wants_library: bool, wipe_accounts: bool
) -> None:
    if wants_patch:
        await session.execute(delete(SteamPatchRoot))
    if wants_library:
        await session.execute(delete(GameTag))
        await session.execute(delete(GameVersion))
        await session.execute(delete(Game))
        await session.execute(delete(Company))
        await session.execute(delete(IgnoreList))
        await session.execute(delete(RootDirectory))
        if wipe_accounts:
            await session.execute(delete(UserSession))
            await session.execute(delete(User))
    await session.flush()


async def apply_restore(config, archive: Path, payload: dict[str, Any], *,
                        scope: str, mode: str, media_policy: str) -> dict[str, Any]:
    lines: list[str] = []
    stats: dict[str, int] = {}
    wants_patch = scope in {SCOPE_ALL, SCOPE_PATCH}
    wants_library = scope in {SCOPE_ALL, SCOPE_LIBRARY} and _has_library_section(
        payload["library"]
    )
    replace = mode == MODE_REPLACE

    lock_path = Path(config.data_path or "/data") / ".restore.lock"
    with ExitStack() as stack:
        acquired = stack.enter_context(process_lock(lock_path, blocking=False))
        if not acquired:
            fail("另一个恢复任务正在进行，请稍后再试", 4)
        scan_idle = stack.enter_context(
            process_lock(scan_lock_path(config.data_path), blocking=False)
        )
        if not scan_idle:
            fail("扫描任务正在进行，请稍后再试", 4)
        journal = _RestoreJournal.begin(config)
        logger.info(
            "Restore started: scope=%s mode=%s media=%s", scope, mode, media_policy
        )
        try:
            available_media = {kind: set() for kind in MEDIA_KINDS}
            if wants_library:
                available_media = await asyncio.to_thread(
                    apply_media, config, archive, payload["media"], journal
                )

            account_entries = payload["accounts"].get("users") or []
            wiped_accounts = replace and wants_library and bool(account_entries)
            source_stats: dict[str, int] = {}
            async with db._session_factory() as session:
                had_admin = (
                    await session.execute(
                        select(User).where(User.role == "admin")
                    )
                ).scalars().first() is not None
                if replace:
                    await _clear_selected(
                        session,
                        wants_patch=wants_patch,
                        wants_library=wants_library,
                        wipe_accounts=wiped_accounts,
                    )

                if wants_library or wants_patch:
                    source_stats, source_map, _ = await import_file_sources(
                        session,
                        (payload["library"].get("file_sources") or []),
                        replace=replace,
                    )
                else:
                    source_map = {}

                library_stats: dict[str, int] = {}
                if wants_library:
                    library_stats, library_notes = await import_library(
                        config,
                        session,
                        payload["library"],
                        replace=replace,
                        source_map=source_map,
                        available_media=available_media,
                        overwrite_media=media_policy == MEDIA_OVERWRITE,
                    )
                else:
                    library_notes = []

                patch_root_stats: dict[str, int] = {}
                if wants_patch:
                    patch_root_stats, patch_notes = await import_patch_roots(
                        session, payload["patch_roots"], source_map
                    )
                else:
                    patch_notes = []

                account_stats: dict[str, int] = {}
                if wants_library:
                    account_stats, account_notes = await import_accounts(
                        config, session, payload["accounts"],
                        available_media=available_media,
                    )
                else:
                    account_notes = []

                if wants_library and (account_entries or had_admin):
                    await _ensure_admin(session)
                await session.commit()

            stats.update(source_stats)
            stats.update(library_stats)
            stats.update(patch_root_stats)
            stats.update(account_stats)
            stats["media_written"] = sum(len(items) for items in available_media.values())

            if wants_patch and (
                payload["rules"] or payload["keywords"] or payload["patch_roots"]
            ):
                patch_lines, patch_stats = await asyncio.to_thread(
                    _apply_patch_files,
                    config,
                    payload,
                    mode,
                    journal,
                    source_map,
                )
                stats.update(patch_stats)
                lines.extend(patch_lines)

            if wants_library:
                lines.append(
                    "文件源: "
                    f"{stats.get('sources_new', 0)} 新建/"
                    f"{stats.get('sources_updated', 0)} 更新"
                )
                lines.append(
                    "游戏库: "
                    f"目录库 {stats.get('roots_new', 0)} 新建/"
                    f"{stats.get('roots_matched', 0)} 匹配，"
                    f"游戏 {stats.get('games_new', 0)} 新增/"
                    f"{stats.get('games_updated', 0)} 更新/"
                    f"{stats.get('games_skipped', 0)} 跳过，"
                    f"版本 {stats.get('versions_new', 0)} 新增/"
                    f"{stats.get('versions_updated', 0)} 更新，"
                    f"标签 {stats.get('tags_new', 0)} 新增（关联 {stats.get('game_tags', 0)}）"
                )
                lines.append(
                    f"账号: {stats.get('users_new', 0)} 新增/"
                    f"{stats.get('users_updated', 0)} 更新，"
                    f"失效登录态 {stats.get('sessions_revoked', 0)} 个"
                )
                for note in (library_notes + account_notes)[:10]:
                    lines.append(f"注意: {note}")
                lines.extend(import_settings(config, payload.get("settings") or {}, journal))

            if wants_patch and patch_root_stats:
                lines.append(
                    "补丁库目录: "
                    f"{patch_root_stats.get('patch_roots_new', 0)} 新建/"
                    f"{patch_root_stats.get('patch_roots_matched', 0)} 匹配"
                    + (
                        f"，跳过 {patch_root_stats['patch_roots_skipped']}"
                        if patch_root_stats.get("patch_roots_skipped")
                        else ""
                    )
                )
            for note in patch_notes[:5]:
                lines.append(f"注意: {note}")

            journal.finish()
        except Exception as exc:
            rollback_lines = journal.rollback()
            for line in rollback_lines:
                echo(line)
            journal.finish()
            logger.error(
                "Restore failed: error=%s rollback=%s",
                redact_exception(exc),
                "clean" if not rollback_lines else "partial",
                exc_info=True,
            )
            # Put the in-memory settings back in sync with the restored files.
            try:
                from api.settings import _load_scan_settings
                from config import reload_persisted_scraper_config

                _load_scan_settings(config)
                reload_persisted_scraper_config(config)
            except Exception:
                pass
            raise

    return {
        "lines": lines,
        "stats": stats,
        "relogin_required": bool(stats.get("sessions_revoked") or wiped_accounts),
    }


def _resolve_rules(
    rules: list[dict[str, Any]], source_map: dict[str, int]
) -> tuple[list[dict[str, Any]], list[str]]:
    """Point backup rules at the restored file sources and rebuild their paths."""
    resolved: list[dict[str, Any]] = []
    notes: list[str] = []
    for item in rules:
        identity = dict(item.get("identity") or {})
        rule = dict(item.get("rule") or {})
        source_key = identity.pop("source_key", None)
        if str(identity.get("source_type") or "local") == "openlist":
            source_id = source_map.get(str(source_key)) if source_key else None
            if source_id is None:
                notes.append(
                    f"缺少 OpenList 文件源「{identity.get('source_name') or source_key}」，"
                    f"已跳过补丁规则 {identity.get('display_file') or identity.get('file')}"
                )
                continue
            remote = identity.get("source_path") or identity.get("file")
            identity["source_id"] = source_id
            identity["file"] = canonical_source_path("openlist", source_id, remote)
            identity["patch_id"] = f"openlist|{source_id}|{remote}"
        else:
            identity["source_id"] = None
        resolved.append({"identity": identity, "rule": rule})
    return resolved, notes


def _apply_patch_files(config, payload: dict[str, Any], mode: str,
                       journal: "_RestoreJournal",
                       source_map: dict[str, int]) -> tuple[list[str], dict[str, int]]:
    lines: list[str] = []
    stats: dict[str, int] = {"rules_imported": 0, "rules_added": 0}
    rules, rule_notes = _resolve_rules(payload["rules"], source_map)
    for note in rule_notes[:5]:
        lines.append(f"注意: {note}")
    if rules:
        index_path = patch_rules.patch_index_path(config)
        journal.record_file(index_path)
        if index_path.is_file():
            index_data = patch_rules.load_patch_index(index_path)
            patches, rule_stats = patch_rules.preview_restore(
                index_data["patches"], rules, replace=(mode == MODE_REPLACE)
            )
        else:
            index_data = {"patches": []}
            patches, rule_stats = patch_rules.materialise_rules(rules)
            lines.append("补丁索引不存在，已按备份内容重建；下次扫描补丁库会自动补全文件信息")
        index_data["patches"] = patches
        patch_rules.write_json(index_path, index_data)
        stats["rules_imported"] = rule_stats["imported"]
        stats["rules_added"] = rule_stats.get("added", 0)
        lines.append(
            f"补丁规则: 写入 {rule_stats['imported']} 条"
            f"（补全 {rule_stats.get('added', 0)}，变更 {rule_stats['changed']}，"
            f"冲突 {len(rule_stats['conflicts'])}，未匹配 {len(rule_stats['unmatched'])}）"
        )
    keywords = payload["keywords"]
    if keywords:
        keywords_path = patch_rules.keywords_path(config)
        journal.record_file(keywords_path)
        patch_rules.write_json(keywords_path, keywords)
        lines.append(f"补丁类型关键词: 已写入 {len(keywords)} 组")
    return lines, stats


async def cmd_restore(args) -> int:
    config = await prepare_app()
    archive = Path(args.file).expanduser()
    payload = normalise_payload(read_backup_payload(archive))
    yes = bool(getattr(args, "yes", False))

    library = payload["library"]
    accounts = payload["accounts"]
    media_total = sum(len(payload["media"].get(kind) or {}) for kind in MEDIA_KINDS)

    echo("备份内容")
    echo(f"  补丁规则: {len(payload['rules'])} 条"
         + ("（含类型关键词）" if payload["keywords"] else ""))
    echo(f"  游戏库: {len(library.get('games') or [])} 个游戏 / "
         f"{len(library.get('versions') or [])} 个版本 / {len(library.get('tags') or [])} 个标签")
    echo(f"  账号: {len(accounts.get('users') or [])} 个")
    echo(f"  媒体: {media_total} 个文件")

    scope = _ask_scope(payload, yes=yes)
    mode = _ask_mode(yes=yes)
    media_policy = _ask_media_policy(yes=yes) if media_total else MEDIA_SKIP
    if not yes and not confirm("确认开始恢复？", default=True):
        echo("已取消")
        return 130

    result = await apply_restore(
        config, archive, payload, scope=scope, mode=mode, media_policy=media_policy
    )
    for line in result["lines"]:
        echo(line)
    if result["relogin_required"]:
        echo("注意: 登录态已失效，请重新登录客户端")
    return 0
