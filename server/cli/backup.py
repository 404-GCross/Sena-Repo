"""Backup and restore commands for senacli.

A backup is a single zip archive:

    backup.json            structured data (patch rules, library, accounts)
    media/covers/...       cover images referenced by the library
    media/backgrounds/...  background images
    media/avatars/...      user avatars

`senacli backup` writes a zip by default; `--json-only` falls back to a plain
JSON file without media. `senacli restore` asks for the few decisions that
matter and `-y` accepts the defaults (everything, merge, keep existing files).
"""

from __future__ import annotations

import json
import shutil
import zipfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from sqlalchemy import delete, select

import database as db
from cli import patch_rules
from cli.common import choose, confirm, echo, fail, prepare_app
from models.file_source import FileSource
from models.game import Company, Game, GameTag, GameVersion, Platform
from models.ignore_list import IgnoreList
from models.root_directory import RootDirectory
from models.tag import Tag
from models.user import User, UserSession
from services.file_source import canonical_source_path

KIND = "sena_backup"
LEGACY_KIND = "steam_patch_rules"
SCHEMA_VERSION = 3
SUPPORTED_SCHEMA_VERSIONS = (1, 2, 3)
JSON_NAME = "backup.json"
MEDIA_KINDS = ("covers", "backgrounds", "avatars")
SCOPE_ALL = "all"
SCOPE_PATCH = "patch"
SCOPE_LIBRARY = "library"
MODE_MERGE = "merge"
MODE_REPLACE = "replace"
MEDIA_SKIP = "skip"
MEDIA_OVERWRITE = "overwrite"


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


def media_dirs(config) -> dict[str, Path]:
    return {
        "covers": Path(config.covers_path),
        "backgrounds": Path(config.backgrounds_path),
        "avatars": Path(config.data_path or "/data") / "avatars",
    }


def resolve_output(args, config, suffix: str) -> Path:
    directory = getattr(args, "directory", None)
    output = getattr(args, "output", None)
    if directory and output:
        fail("不能同时指定备份目录和 -o 输出文件", 2)
    name = f"sena-backup-{utc_timestamp()}{suffix}"
    if directory:
        target = Path(directory).expanduser()
        if target.suffix.lower() in {".json", ".zip"}:
            fail("backup 后面的路径表示目录；指定文件请使用 -o", 2)
        return target / name
    if output:
        target = Path(output).expanduser()
        if target.exists() and target.is_dir():
            return target / name
        return target
    return backup_dir(config) / name


# ── export ──


async def _export_library(session) -> dict[str, list[dict[str, Any]]]:
    company_rows = list((await session.execute(select(Company))).scalars())
    companies = {c.id: c.name for c in company_rows}
    roots = list((await session.execute(select(RootDirectory))).scalars())
    games = list((await session.execute(select(Game))).scalars())
    versions = list((await session.execute(select(GameVersion))).scalars())
    tags = list((await session.execute(select(Tag))).scalars())
    game_tags = list((await session.execute(select(GameTag))).scalars())
    ignored = list((await session.execute(select(IgnoreList))).scalars())

    game_paths = {g.id: g.folder_path for g in games}
    tag_names = {t.id: t.name for t in tags}
    root_paths = {r.id: r.path for r in roots}

    return {
        "roots": [
            {
                "path": root.path,
                "source_type": root.source_type,
                "source_id": root.source_id,
                "source_name": root.source_name,
                "source_path": root.source_path,
                "enable_batch_scrape": bool(root.enable_batch_scrape),
            }
            for root in roots
        ],
        "companies": [
            {"name": c.name, "created_at": _iso(c.created_at)} for c in company_rows
        ],
        "games": [
            {
                "name": game.name,
                "company": companies.get(game.company_id),
                "root": root_paths.get(game.root_id),
                "folder_path": game.folder_path,
                "entry_source": game.entry_source,
                "cover": _basename(game.cover_path),
                "background": _basename(game.bg_path),
                "is_nsfw": bool(game.is_nsfw),
                "developer": game.developer,
                "description": game.description,
                "release_date": game.release_date,
                "vndb_id": game.vndb_id,
                "steam_id": game.steam_id,
                "bangumi_id": game.bangumi_id,
                "hikarinagi_id": game.hikarinagi_id,
                "length": game.length or 0,
                "length_minutes": game.length_minutes or 0,
                "is_deleted": bool(game.is_deleted),
                "imported_at": _iso(game.imported_at),
                "updated_at": _iso(game.updated_at),
            }
            for game in games
        ],
        "versions": [
            {
                "game": game_paths.get(version.game_id),
                "platform": version.platform.value if version.platform else None,
                "filename": version.filename,
                "file_path": version.file_path,
                "source_type": version.source_type,
                "source_id": version.source_id,
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
                "game": game_paths.get(row.game_id),
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
            }
            for user in users
        ]
    }


async def build_payload(config) -> dict[str, Any]:
    async with db._session_factory() as session:
        library = await _export_library(session)
        accounts = await _export_accounts(session)

    index_path = patch_rules.patch_index_path(config)
    keywords_path = patch_rules.keywords_path(config)
    steam_patch: dict[str, Any] = {}
    if index_path.is_file():
        index_data = patch_rules.load_patch_index(index_path)
        steam_patch["rules"] = patch_rules.rule_entries(index_data["patches"])
    keywords, _ = patch_rules.read_keywords(keywords_path)
    if keywords:
        steam_patch["keywords"] = keywords

    return {
        "kind": KIND,
        "schema_version": SCHEMA_VERSION,
        "app": "Sena-Repo",
        "exported_at": utc_iso(),
        "source": {
            "data_path": str(config.data_path),
            "patch_index": str(index_path),
            "keywords": str(keywords_path),
        },
        "steam_patch": steam_patch,
        "library": library,
        "accounts": accounts,
        "media": {kind: [] for kind in MEDIA_KINDS},
    }


def collect_media(config, payload: dict[str, Any]) -> dict[str, list[Path]]:
    directories = media_dirs(config)
    wanted: dict[str, set[str]] = {kind: set() for kind in MEDIA_KINDS}
    for game in payload["library"].get("games") or []:
        for field, kind in (("cover", "covers"), ("background", "backgrounds")):
            name = _basename(game.get(field))
            if name:
                wanted[kind].add(name)
    for user in payload["accounts"].get("users") or []:
        name = _basename(user.get("avatar"))
        if name:
            wanted["avatars"].add(name)

    found: dict[str, list[Path]] = {}
    for kind in MEDIA_KINDS:
        files = []
        for name in sorted(wanted[kind]):
            path = directories[kind] / name
            if path.is_file():
                files.append(path)
        found[kind] = files
    return found


def write_backup(output: Path, payload: dict[str, Any], media: dict[str, list[Path]],
                 *, include_media: bool) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    if not include_media:
        patch_rules.write_json(output, payload)
        return
    tmp_path = output.with_name(f".{output.name}.tmp")
    with zipfile.ZipFile(tmp_path, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr(JSON_NAME, json.dumps(payload, ensure_ascii=False, indent=2) + "\n")
        for kind, files in media.items():
            for path in files:
                archive.write(path, f"media/{kind}/{path.name}")
    tmp_path.replace(output)


async def cmd_backup(args) -> int:
    config = await prepare_app()
    json_only = bool(getattr(args, "json_only", False))
    output = resolve_output(args, config, ".json" if json_only else ".zip")

    payload = await build_payload(config)
    media = collect_media(config, payload)
    payload["media"] = {kind: [path.name for path in files] for kind, files in media.items()}
    write_backup(output, payload, media, include_media=not json_only)

    library = payload["library"]
    echo(f"已导出备份: {output}")
    echo(f"补丁规则: {len(payload['steam_patch'].get('rules') or [])} 条"
         + ("，含类型关键词" if payload["steam_patch"].get("keywords") else ""))
    echo(f"游戏库: {len(library.get('games') or [])} 个游戏 / "
         f"{len(library.get('versions') or [])} 个版本 / {len(library.get('tags') or [])} 个标签")
    echo(f"账号: {len(payload['accounts'].get('users') or [])} 个")
    if json_only:
        echo("媒体: 未包含（--json-only）")
    else:
        echo(f"媒体: {sum(len(files) for files in media.values())} 个文件")
    echo("提示: 备份包含账号密码哈希与解压密码，请妥善保管。")
    return 0


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
    if data.get("kind") not in {KIND, LEGACY_KIND}:
        fail("备份文件类型不正确，不是 Sena-Repo 备份", 3)
    if data.get("schema_version") not in SUPPORTED_SCHEMA_VERSIONS:
        fail(f"不支持的备份版本: {data.get('schema_version')}", 3)
    return data


def normalise_payload(data: dict[str, Any]) -> dict[str, Any]:
    if data.get("kind") == LEGACY_KIND:
        raw_patch: dict[str, Any] = {"rules": data.get("rules"), "keywords": data.get("keywords")}
    else:
        raw_patch = data.get("steam_patch") or {}
    rules = raw_patch.get("rules")
    return {
        "rules": rules if isinstance(rules, list) else [],
        "keywords": patch_rules.normalise_keywords(raw_patch.get("keywords")),
        "library": data.get("library") if isinstance(data.get("library"), dict) else {},
        "accounts": data.get("accounts") if isinstance(data.get("accounts"), dict) else {},
        "media": data.get("media") if isinstance(data.get("media"), dict) else {},
    }


# ── import ──


def _platform(value: Any) -> Platform:
    try:
        return Platform(str(value or "PC").strip())
    except ValueError:
        return Platform.PC


async def import_library(config, session, library: dict[str, Any], *,
                         replace: bool) -> tuple[dict[str, int], list[str]]:
    stats = {
        "roots_new": 0, "roots_matched": 0, "roots_skipped": 0,
        "games_new": 0, "games_updated": 0, "games_skipped": 0,
        "versions_new": 0, "versions_updated": 0,
        "tags_new": 0, "tags_updated": 0, "game_tags": 0,
        "companies_new": 0, "ignored_new": 0,
    }
    notes: list[str] = []

    if replace:
        await session.execute(delete(GameTag))
        await session.execute(delete(GameVersion))
        await session.execute(delete(Game))
        await session.execute(delete(Company))
        await session.execute(delete(IgnoreList))
        await session.flush()

    sources = list((await session.execute(select(FileSource))).scalars())
    sources_by_id = {source.id: source for source in sources}
    sources_by_name = {source.name: source for source in sources if source.name}
    existing_roots = {
        root.path: root for root in (await session.execute(select(RootDirectory))).scalars()
    }
    root_by_backup_path: dict[str, RootDirectory] = {}
    prefix_map: list[tuple[str, str]] = []
    source_id_map: dict[int, int] = {}

    for entry in library.get("roots") or []:
        old_path = str(entry.get("path") or "").strip()
        if not old_path:
            continue
        source_type = str(entry.get("source_type") or "local")
        source_id = entry.get("source_id")
        source_name = entry.get("source_name")
        if source_type == "openlist":
            # Match by name first: ids only line up on the machine that made the backup.
            source = sources_by_name.get(source_name) if source_name else None
            if source is None and source_id is not None:
                candidate = sources_by_id.get(source_id)
                if candidate is not None and (not source_name or candidate.name == source_name):
                    source = candidate
            if source is None:
                stats["roots_skipped"] += 1
                notes.append(
                    f"缺少 OpenList 文件源「{source_name or source_id}」，"
                    f"请先在服务端配置同名源；已跳过目录库 {old_path}"
                )
                continue
            if source_id is not None and source_id != source.id:
                source_id_map[int(source_id)] = source.id
            source_id = source.id
            source_name = source.name
        new_path = canonical_source_path(source_type, source_id, entry.get("source_path") or old_path)
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
            stats["roots_matched"] += 1
        root_by_backup_path[old_path] = root
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
    games_by_path = {
        game.folder_path: game for game in (await session.execute(select(Game))).scalars()
    }
    game_ids: dict[str, int] = {}
    directories = media_dirs(config)

    for entry in library.get("games") or []:
        old_folder = str(entry.get("folder_path") or "").strip()
        if not old_folder:
            continue
        root = root_by_backup_path.get(str(entry.get("root") or ""))
        if root is None:
            stats["games_skipped"] += 1
            notes.append(f"缺少目录库，已跳过游戏 {entry.get('name') or old_folder}")
            continue

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
        cover_name = _basename(entry.get("cover"))
        background_name = _basename(entry.get("background"))
        fields = {
            "name": entry.get("name") or _basename(folder_path) or folder_path,
            "company_id": company.id if company else None,
            "root_id": root.id,
            "folder_path": folder_path,
            "entry_source": entry.get("entry_source") or "library",
            "cover_path": str(directories["covers"] / cover_name) if cover_name else None,
            "bg_path": str(directories["backgrounds"] / background_name) if background_name else None,
            "is_nsfw": bool(entry.get("is_nsfw", False)),
            "developer": entry.get("developer"),
            "description": entry.get("description"),
            "release_date": entry.get("release_date"),
            "vndb_id": entry.get("vndb_id"),
            "steam_id": entry.get("steam_id"),
            "bangumi_id": entry.get("bangumi_id"),
            "hikarinagi_id": entry.get("hikarinagi_id"),
            "length": entry.get("length") or 0,
            "length_minutes": entry.get("length_minutes") or 0,
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
        else:
            for key, value in fields.items():
                setattr(game, key, value)
            stats["games_updated"] += 1
        updated_at = _parse_dt(entry.get("updated_at"))
        if updated_at is not None:
            game.updated_at = updated_at
        game_ids[old_folder] = game.id

    versions = {
        (version.game_id, version.file_path): version
        for version in (await session.execute(select(GameVersion))).scalars()
    }
    for entry in library.get("versions") or []:
        game_id = game_ids.get(str(entry.get("game") or ""))
        if game_id is None:
            continue
        file_path = remap(entry.get("file_path"))
        if not file_path:
            continue
        source_id = entry.get("source_id")
        if source_id is not None:
            source_id = source_id_map.get(int(source_id), source_id)
        data = {
            "game_id": game_id,
            "platform": _platform(entry.get("platform")),
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
            for key, value in data.items():
                setattr(version, key, value)
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
        game_id = game_ids.get(str(entry.get("game") or ""))
        tag = tags.get(str(entry.get("tag") or ""))
        if game_id is None or tag is None:
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


async def import_accounts(config, session, accounts: dict[str, Any], *,
                          replace: bool) -> tuple[dict[str, int], list[str]]:
    stats = {"users_new": 0, "users_updated": 0, "users_skipped": 0, "sessions_revoked": 0}
    notes: list[str] = []
    entries = accounts.get("users") or []
    if not entries:
        return stats, notes

    if replace:
        await session.execute(delete(UserSession))
        await session.execute(delete(User))
        await session.flush()

    avatars_dir = media_dirs(config)["avatars"]
    existing = {
        user.username: user for user in (await session.execute(select(User))).scalars()
    }
    owner_taken = next((u.username for u in existing.values() if u.role == "owner"), None)

    for entry in entries:
        username = str(entry.get("username") or "").strip()
        if not username:
            stats["users_skipped"] += 1
            continue
        role = str(entry.get("role") or "user")
        if role == "owner" and owner_taken and owner_taken != username:
            stats["users_skipped"] += 1
            notes.append(f"服务端已有服主「{owner_taken}」，已跳过备份中的服主「{username}」")
            continue
        avatar_name = _basename(entry.get("avatar"))
        fields = {
            "password_hash": entry.get("password_hash") or "",
            "salt": entry.get("salt") or "",
            "role": role,
            "is_admin": role in {"owner", "admin"} or bool(entry.get("is_admin")),
            "status": str(entry.get("status") or "active"),
            "avatar_path": str(avatars_dir / avatar_name) if avatar_name else None,
        }
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
            if role == "owner":
                owner_taken = username
            continue
        password_changed = user.password_hash != fields["password_hash"]
        for key, value in fields.items():
            setattr(user, key, value)
        stats["users_updated"] += 1
        if password_changed:
            revoked = await session.execute(
                delete(UserSession).where(UserSession.user_id == user.id)
            )
            stats["sessions_revoked"] += int(revoked.rowcount or 0)

    return stats, notes


def apply_media(config, archive: Path, manifest: dict[str, Any], *, policy: str) -> dict[str, int]:
    stats = {"written": 0, "skipped": 0}
    if not archive.is_file() or not zipfile.is_zipfile(archive):
        return stats
    directories = media_dirs(config)
    with zipfile.ZipFile(archive) as source:
        names = set(source.namelist())
        for kind in MEDIA_KINDS:
            target_dir = directories[kind]
            for name in manifest.get(kind) or []:
                base = _basename(name)
                if not base:
                    continue
                entry = f"media/{kind}/{base}"
                if entry not in names:
                    continue
                target_dir.mkdir(parents=True, exist_ok=True)
                destination = target_dir / base
                if destination.exists() and policy == MEDIA_SKIP:
                    stats["skipped"] += 1
                    continue
                with source.open(entry) as src, open(destination, "wb") as dst:
                    shutil.copyfileobj(src, dst)
                stats["written"] += 1
    return stats


# ── restore ──


def _ask_scope(payload: dict[str, Any], *, yes: bool) -> str:
    has_patch = bool(payload["rules"] or payload["keywords"])
    has_library = bool(payload["library"] or payload["accounts"])
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
        "目标目录已有同名图片/头像时：",
        [(MEDIA_SKIP, "跳过已有文件"), (MEDIA_OVERWRITE, "全部覆盖")],
        default=MEDIA_SKIP,
    )


async def apply_restore(config, archive: Path, payload: dict[str, Any], *,
                        scope: str, mode: str, media_policy: str) -> dict[str, Any]:
    lines: list[str] = []
    safety_dir = backup_dir(config)
    wants_patch = scope in {SCOPE_ALL, SCOPE_PATCH}
    wants_library = scope in {SCOPE_ALL, SCOPE_LIBRARY}

    if wants_patch and (payload["rules"] or payload["keywords"]):
        index_path = patch_rules.patch_index_path(config)
        if payload["rules"]:
            if not index_path.is_file():
                fail(f"补丁索引不存在，请先扫描补丁库: {index_path}", 3)
            index_data = patch_rules.load_patch_index(index_path)
            patches, stats = patch_rules.preview_restore(
                index_data["patches"], payload["rules"], replace=(mode == MODE_REPLACE)
            )
            safety = safety_dir / f"patches-before-restore-{utc_timestamp()}.json"
            safety.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(index_path, safety)
            index_data["patches"] = patches
            patch_rules.write_json(index_path, index_data)
            lines.append(
                f"补丁规则: 写入 {stats['imported']} 条（变更 {stats['changed']}，"
                f"冲突 {len(stats['conflicts'])}，未匹配 {len(stats['unmatched'])}）"
            )
            lines.append(f"恢复前索引备份: {safety}")
        if payload["keywords"]:
            keywords_path = patch_rules.keywords_path(config)
            if keywords_path.is_file():
                safety = safety_dir / f"keywords-before-restore-{utc_timestamp()}.json"
                safety.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(keywords_path, safety)
                lines.append(f"恢复前关键词备份: {safety}")
            patch_rules.write_json(keywords_path, payload["keywords"])
            lines.append(f"补丁类型关键词: 已写入 {len(payload['keywords'])} 组")

    if wants_library and (payload["library"] or payload["accounts"]):
        async with db._session_factory() as session:
            library_stats, library_notes = await import_library(
                config, session, payload["library"], replace=(mode == MODE_REPLACE)
            )
            account_stats, account_notes = await import_accounts(
                config, session, payload["accounts"], replace=(mode == MODE_REPLACE)
            )
            await session.commit()
        lines.append(
            "游戏库: "
            f"目录库 {library_stats['roots_new']} 新建/{library_stats['roots_matched']} 匹配，"
            f"游戏 {library_stats['games_new']} 新增/{library_stats['games_updated']} 更新，"
            f"版本 {library_stats['versions_new']} 新增/{library_stats['versions_updated']} 更新，"
            f"标签 {library_stats['tags_new']} 新增（关联 {library_stats['game_tags']}）"
        )
        lines.append(
            f"账号: {account_stats['users_new']} 新增/{account_stats['users_updated']} 更新，"
            f"失效登录态 {account_stats['sessions_revoked']} 个"
        )
        for note in (library_notes + account_notes)[:10]:
            lines.append(f"注意: {note}")

    if wants_library:
        media_stats = apply_media(config, archive, payload["media"], policy=media_policy)
        if media_stats["written"] or media_stats["skipped"]:
            lines.append(
                f"媒体: 写入 {media_stats['written']} 个，跳过 {media_stats['skipped']} 个"
            )

    return {"lines": lines}


async def cmd_restore(args) -> int:
    config = await prepare_app()
    archive = Path(args.file).expanduser()
    payload = normalise_payload(read_backup_payload(archive))
    yes = bool(getattr(args, "yes", False))

    library = payload["library"]
    accounts = payload["accounts"]
    media_total = sum(len(payload["media"].get(kind) or []) for kind in MEDIA_KINDS)

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
    if media_total and media_policy == MEDIA_OVERWRITE:
        echo("同名文件按「全部覆盖」处理")
    return 0
