from __future__ import annotations

import asyncio
import hashlib
import json
import logging
import posixpath
import threading
from collections import defaultdict
from datetime import datetime
from pathlib import Path

import httpx
from pydantic import BaseModel, Field
from sqlalchemy import func, select
from sqlalchemy.orm import selectinload

import database
from config import load_config
from models.agent import AgentJob, AgentResult
from models.file_source import FileSource
from models.game import Game, GameVersion, PlatformCategory
from models.root_directory import RootDirectory
from services.agent.inventory import inventory, inspect_file, relative_path
from services.agent.metadata import Catalog, select_metadata
from services.agent.providers import ModelError, tool_spec
from services.agent.runtime import (
    AgentBudget,
    AgentConfigurationChanged,
    AgentStopped,
    Runtime,
    object_schema,
)
from services.agent.settings import load_settings
from services.file_source import canonical_source_path, adapter_from_source
from services.importer import import_from_root, scanner_ignore_paths
from services.scanner import (
    ArchiveFile,
    CompanyFolder,
    GameFolder,
    get_ignore_paths,
    scan_root,
    scan_source,
)
from services.scraper.orchestrator import _apply_result, scrape_single_game
from utils.process_lock import process_lock, scan_lock_path

logger = logging.getLogger(__name__)
_tasks: dict[int, asyncio.Task] = {}


def fallback_details(error):
    if isinstance(error, AgentConfigurationChanged):
        return "config_fallback", "模型配置已变化，本项使用常规流程"
    if isinstance(error, AgentBudget):
        return "budget_fallback", f"{error}；本项转常规流程，不代表无法识别"
    if isinstance(error, ModelError):
        return "model_fallback", f"{error}；本项转常规流程"
    if isinstance(error, ValueError):
        return "validation_fallback", "智能体结果未通过校验，本项转常规流程"
    return (
        "source_fallback",
        f"文件或资料源处理失败（{type(error).__name__}），本项转常规流程",
    )


async def collect_inventory(runtime, root, source, ignored):
    stopped = threading.Event()
    progress = [None]
    kind = "补丁" if runtime.job.kind == "patch" else "游戏"
    location = "OpenList" if root.source_type == "openlist" else "本地"
    prefix = f"正在列举{location}{kind}目录"
    runtime.job.message = f"{prefix}，等待文件源响应；此阶段尚不调用模型"
    await runtime.session.commit()

    def report(directories, entries, files):
        progress[0] = (directories, entries, files)

    worker = asyncio.create_task(
        asyncio.to_thread(
            inventory,
            root,
            source,
            ignored,
            on_progress=report,
            stop_requested=stopped.is_set,
        )
    )
    last = None
    try:
        while True:
            done, _ = await asyncio.wait({worker}, timeout=1)
            await runtime.check()
            current = progress[0]
            if current is not None and current != last:
                directories, entries, files = current
                runtime.job.message = (
                    f"{prefix}：已遍历 {directories} 个目录、{entries} 个条目，"
                    f"发现 {files} 个候选文件；清单完成后开始模型分析"
                )
                await runtime.session.commit()
                last = current
            if done:
                return worker.result()
    except BaseException:
        stopped.set()
        try:
            await asyncio.shield(worker)
        except BaseException:
            pass
        raise


class Group(BaseModel):
    candidate: int = Field(ge=0)
    files: list[int] = Field(min_length=1, max_length=100)
    evidence: str = Field(min_length=1, max_length=2000)


class Discovery(BaseModel):
    groups: list[Group] = Field(default_factory=list, max_length=40)


class PatchSelection(BaseModel):
    candidate: int = Field(ge=0)
    patch_dir: str = Field(default="", max_length=512)
    target_dir: str = Field(default="", max_length=512)
    copy_only: bool = False
    instruction_quote: str = Field(default="", max_length=1000)
    evidence: str = Field(min_length=1, max_length=2000)


def fingerprint(data, settings):
    public = settings.model_dump(
        exclude={"api_key", "proxy_password", "proxy_username", "proxy_url"}
    )
    return hashlib.sha256(
        json.dumps(
            [data, public], sort_keys=True, ensure_ascii=False, default=str
        ).encode()
    ).hexdigest()


async def record(runtime, key, digest, status, summary, data=None):
    await runtime.session.refresh(runtime.job)
    runtime.session.add(
        AgentResult(
            job_id=runtime.job.id,
            key=str(key)[:1024],
            fingerprint=digest,
            status=status,
            summary=summary[:2000],
            data=data or {},
        )
    )
    runtime.job.message = summary[:500]
    await runtime.session.commit()


async def cached(runtime, digest):
    if runtime.job.request.get("retry"):
        return None
    return (
        await runtime.session.execute(
            select(AgentResult)
            .where(AgentResult.fingerprint == digest, AgentResult.status == "applied")
            .order_by(AgentResult.id.desc())
            .limit(1)
        )
    ).scalar_one_or_none()


async def inspect_tool(root, source, batch, settings, args):
    index = args.get("file")
    item = next((f for f in batch if f["id"] == index), None)
    if item is None:
        return {"error": "Unknown inventory ID"}
    return await inspect_file(root, source, item, settings)


async def discover_root(runtime, root):
    session, config = runtime.session, load_config()
    source = await session.get(FileSource, root.source_id) if root.source_id else None
    ignored = await get_ignore_paths(session)
    source_path = root.source_path or root.path
    assigned, groups, existing = set(), [], {}
    identity_groups = {}
    known_identities = {}
    id_fields = {
        "steam": "steam_id",
        "vndb_kana": "vndb_id",
        "bangumi": "bangumi_id",
        "hikarinagi": "hikarinagi_id",
        "nextmoe": "nextmoe_id",
    }
    for saved in (
        await session.execute(
            select(Game).where(Game.root_id == root.id, Game.is_deleted.is_(False))
        )
    ).scalars():
        for provider, field in id_fields.items():
            if getattr(saved, field):
                identity = (provider, str(getattr(saved, field)))
                known_identities[identity] = (
                    saved.id if identity not in known_identities else None
                )
    known = (
        (
            await session.execute(
                select(GameVersion).join(Game).where(Game.root_id == root.id)
            )
        )
        .scalars()
        .all()
    )
    for version in known:
        existing[version.source_path or version.file_path] = version.game_id
    catalog = Catalog(config, runtime.job.actor_id, runtime)
    try:
        try:
            files = await collect_inventory(runtime, root, source, ignored)
        except AgentStopped:
            raise
        except Exception:
            files = []
            await record(
                runtime, root.id, "", "fallback", "目录无法进行智能分析，使用常规扫描"
            )
        batches = defaultdict(list)
        for item in files:
            batches[posixpath.dirname(item["relative"])].append(item)
        for parent, siblings in batches.items():
            if not any(
                f["archive"] or f["relative"].lower().endswith(".exe") for f in siblings
            ):
                continue
            for start in range(0, len(siblings), 40):
                await runtime.check()
                batch = siblings[start : start + 40]
                snapshot = [
                    {k: f[k] for k in ("id", "relative", "size", "modified", "archive")}
                    for f in batch
                ]
                digest = fingerprint(
                    [root.id, source_path, root.source_id, snapshot], runtime.settings
                )
                old = (
                    await session.execute(
                        select(AgentResult)
                        .where(
                            AgentResult.fingerprint == digest,
                            AgentResult.status == "identified",
                        )
                        .order_by(AgentResult.id.desc())
                        .limit(1)
                    )
                ).scalar_one_or_none()
                if old is not None and not runtime.job.request.get("retry"):
                    batch_archives = [f for f in batch if f["archive"]]
                    if batch_archives and all(
                        f["path"] in existing for f in batch_archives
                    ):
                        assigned.update(f["path"] for f in batch_archives)
                        await record(
                            runtime,
                            parent or str(root.id),
                            digest,
                            "cached",
                            "复用未变化目录的现有归组",
                        )
                        continue
                tools = catalog.tools()
                tools["inspect_file"] = (
                    tool_spec(
                        "inspect_file",
                        "Read archive listing or bounded instructions from this inventory",
                        object_schema({"file": {"type": "integer"}}),
                    ),
                    lambda args, batch=batch: inspect_tool(
                        root, source, batch, runtime.settings, args
                    ),
                )
                try:
                    data = await runtime.reason(
                        "discovery",
                        {
                            "files": snapshot,
                            "sources": [s.source_name for s in catalog.scrapers],
                        },
                        Discovery.model_json_schema(),
                        tools,
                    )
                    proposals = Discovery.model_validate(data).groups
                    accepted = []
                    for proposal in proposals:
                        if proposal.candidate >= len(catalog.results):
                            continue
                        selected = [f for f in batch if f["id"] in proposal.files]
                        if len(selected) != len(set(proposal.files)) or any(
                            f["path"] in assigned for f in selected
                        ):
                            continue
                        owners = {
                            existing[f["path"]]
                            for f in selected
                            if f["path"] in existing
                        }
                        if len(owners) > 1:
                            await record(
                                runtime,
                                parent,
                                digest,
                                "review",
                                "文件已属于多个游戏，保留原归组",
                            )
                            continue
                        result = catalog.results[proposal.candidate]
                        identity = (result.source_name, result.source_id)
                        if not owners and known_identities.get(identity):
                            owners.add(known_identities[identity])
                        archives = [
                            ArchiveFile(Path(f["path"]).name, f["path"], f["size"])
                            for f in selected
                            if f["archive"]
                        ]
                        executables = [
                            f
                            for f in selected
                            if f["relative"].lower().endswith(".exe")
                        ]
                        if not archives and not executables:
                            continue
                        path = (
                            archives[0].filepath
                            if archives
                            else posixpath.dirname(executables[0]["path"])
                        )
                        if owners:
                            owner = await session.get(Game, next(iter(owners)))
                            if owner.metadata_locked or owner.name_locked:
                                assigned.update(f["path"] for f in selected)
                                continue
                            path = owner.folder_path
                            prefix = f"openlist://{root.source_id or 0}"
                            if path.startswith(prefix):
                                path = path[len(prefix) :]
                        if identity in identity_groups:
                            target = identity_groups[identity]
                            if owners and target.path != path:
                                await record(
                                    runtime,
                                    parent,
                                    digest,
                                    "review",
                                    "同一作品已有不同归组，保留管理员的现有记录",
                                )
                                continue
                            target.archives.extend(archives)
                        else:
                            target = GameFolder(result.title, path, archives)
                            identity_groups[identity] = target
                            groups.append(
                                CompanyFolder(
                                    result.developer or "未知会社",
                                    source_path,
                                    [target],
                                )
                            )
                        assigned.update(f["path"] for f in selected)
                        accepted.append(
                            {
                                "name": result.title,
                                "source": result.source_name,
                                "source_id": result.source_id,
                                "evidence": proposal.evidence,
                                "directory_only": not archives,
                            }
                        )
                    remaining = sum(
                        (f["archive"] or f["relative"].lower().endswith(".exe"))
                        and f["path"] not in assigned
                        for f in batch
                    )
                    if accepted:
                        outcome = "partial" if remaining else "identified"
                        summary = f"已识别 {len(accepted)} 组游戏"
                        if remaining:
                            summary += f"；另有 {remaining} 个候选文件交给常规扫描"
                    else:
                        outcome = "unmatched" if remaining else "skipped"
                        summary = (
                            "未获得可验证的匹配，交给常规扫描"
                            if remaining
                            else "保留已有锁定或归组记录"
                        )
                    await record(
                        runtime,
                        parent or str(root.id),
                        digest,
                        outcome,
                        summary,
                        {"groups": accepted, "unresolved_files": remaining},
                    )
                except (ModelError, ValueError) as exc:
                    outcome, summary = fallback_details(exc)
                    await record(
                        runtime,
                        parent or str(root.id),
                        digest,
                        outcome,
                        summary,
                    )
        await runtime.check()
        exclusions = (
            scanner_ignore_paths(root.source_type or "local", root.source_id, ignored)
            | assigned
        )
        structure, depth = (
            getattr(config, "_scan_structure", "company_game"),
            getattr(config, "_scan_depth", None),
        )
        if root.source_type == "openlist":
            regular = await asyncio.to_thread(
                scan_source,
                adapter_from_source(source, "openlist"),
                source_path,
                exclusions,
                structure,
                depth,
            )
        else:
            regular = await asyncio.to_thread(
                scan_root, source_path, exclusions, structure, depth
            )
        regular.companies = [
            CompanyFolder(c.name, c.path, [g for g in c.games if g.archives])
            for c in regular.companies
        ]
        accounted = assigned | {
            a.filepath for c in regular.companies for g in c.games for a in g.archives
        }
        unresolved = [
            f["relative"]
            for f in files
            if f["path"] not in accounted
            and (f["archive"] or f["relative"].lower().endswith(".exe"))
        ]
        if unresolved:
            await record(
                runtime,
                root.id,
                "",
                "review",
                f"{len(unresolved)} 个文件尚未识别，保留原文件待确认",
                {"files": unresolved[:200]},
            )
        regular.companies.extend(groups)
        await import_from_root(
            root.id, config, session, scan_override=regular, preserve_unseen=True
        )
        return files
    finally:
        await catalog.close()


async def scrape_game(runtime, game, client):
    session, config = runtime.session, load_config()
    if game.metadata_locked:
        return
    versions = (
        (
            await session.execute(
                select(GameVersion).where(GameVersion.game_id == game.id)
            )
        )
        .scalars()
        .all()
    )
    state = lambda: [
        game.id,
        game.name,
        game.cover_path,
        game.description,
        game.developer,
        game.alias,
        [(v.file_path, v.file_size, v.platform) for v in versions],
    ]
    snapshot = state()
    digest = fingerprint(snapshot, runtime.settings)
    if await cached(runtime, digest):
        await record(runtime, game.id, digest, "cached", "复用未变化条目的已应用结果")
        return
    catalog = Catalog(config, runtime.job.actor_id, runtime)
    platforms = set((await session.execute(select(PlatformCategory.name))).scalars())
    try:
        try:
            result, evidence = await select_metadata(
                runtime,
                catalog,
                {
                    "game": game.name,
                    "files": [
                        {"id": v.id, "filename": v.filename, "platform": v.platform}
                        for v in versions
                    ][:100],
                    "allowed_platforms": sorted(platforms),
                    "saved_ids": {
                        k: getattr(game, k)
                        for k in (
                            "vndb_id",
                            "steam_id",
                            "bangumi_id",
                            "hikarinagi_id",
                            "nextmoe_id",
                        )
                    },
                },
            )
            original_updated = game.updated_at
            await session.refresh(game)
            if game.metadata_locked or game.updated_at != original_updated:
                await record(
                    runtime,
                    game.id,
                    digest,
                    "review",
                    "分析期间条目已修改，保留最新数据",
                )
                return
            await runtime.check()
            await _apply_result(
                result,
                result.source_name,
                game,
                client,
                config.covers_path,
                session,
                config,
                runtime.settings.update_mode,
            )
            if not game.name_locked:
                game.name = result.title or game.name
            for version in versions:
                platform = catalog.selection.platforms.get(str(version.id))
                if platform in platforms and version.platform == "未分类":
                    version.platform = platform
            await session.commit()
            # Fill only missing fields so fallback cannot replace the selected cover.
            if (
                not game.description
                or not game.developer
                or (
                    not game.cover_path
                    and runtime.settings.cover_fallback == "original"
                )
            ):
                await scrape_single_game(
                    game,
                    catalog.scrapers,
                    client,
                    config.covers_path,
                    session,
                    config,
                    "missing",
                )
            digest = fingerprint(state(), runtime.settings)
            await record(
                runtime,
                game.id,
                digest,
                "applied",
                evidence,
                {"game_id": game.id, "name": game.name, "source": result.source_name},
            )
        except (ModelError, ValueError) as exc:
            outcome, summary = fallback_details(exc)
            await runtime.check()
            await scrape_single_game(
                game,
                catalog.scrapers,
                client,
                config.covers_path,
                session,
                config,
                "missing",
            )
            await record(
                runtime,
                game.id,
                digest,
                outcome,
                summary,
                {"game_id": game.id},
            )
    finally:
        await catalog.close()


async def patch_scan(runtime):
    from api import steam_patch as api
    from scan_patches import (
        _enrich_identity,
        _guess_app_id,
        _guess_type,
        DEFAULT_TYPE_KEYWORDS,
    )

    session, config = runtime.session, load_config()
    index = api._get_patch_index_dir(config)
    index.mkdir(parents=True, exist_ok=True)
    roots = await api._patch_roots(session)
    current = api._load_all_patches(index)
    by_id = {api._make_patch_id(p): p for p in current}
    for root in roots:
        source = (
            await session.get(FileSource, root.source_id) if root.source_id else None
        )
        try:
            files = await collect_inventory(runtime, root, source, set())
        except AgentStopped:
            raise
        except Exception:
            from scan_patches import scan_patches_dir, scan_patches_source

            try:
                if root.source_type == "openlist":
                    fallback = await asyncio.to_thread(
                        scan_patches_source,
                        adapter_from_source(source, "openlist"),
                        root.path,
                        "openlist",
                        root.source_id,
                        root.analysis_mode,
                    )
                else:
                    fallback = await asyncio.to_thread(
                        scan_patches_dir, Path(root.path), root.analysis_mode
                    )
                    for entry in fallback:
                        entry["source_path"] = str(Path(root.path) / entry["file"])
                        entry["file"] = entry["source_path"]
                        entry["source_type"] = "local"
                        entry["source_id"] = None
                await runtime.check()
                latest = {
                    api._make_patch_id(p): p for p in api._load_all_patches(index)
                }
                for entry in fallback:
                    entry.pop("patch_id", None)
                    key = api._make_patch_id(entry)
                    old = latest.get(key, {})
                    if old.get("locked"):
                        continue
                    latest[key] = {
                        **entry,
                        **{k: v for k, v in old.items() if v not in (None, "")},
                        "size": entry.get("size", 0),
                    }
                target = index / "patches.json"
                temp = target.with_suffix(".agent.tmp")
                temp.write_text(
                    json.dumps({"patches": list(latest.values())}, ensure_ascii=False),
                    encoding="utf-8",
                )
                temp.replace(target)
                await record(
                    runtime,
                    root.id,
                    "",
                    "fallback",
                    "智能清单不可用，该目录已使用常规补丁扫描",
                )
            except AgentStopped:
                raise
            except Exception:
                await record(
                    runtime,
                    root.id,
                    "",
                    "review",
                    "补丁目录无法读取，已保留原索引；请检查来源连接",
                )
            continue
        for item in files:
            if not item["archive"]:
                continue
            await runtime.check()
            record_data = {
                "file": canonical_source_path(
                    root.source_type, root.source_id, item["path"]
                ),
                "source_path": item["path"],
                "source_type": root.source_type,
                "source_id": root.source_id,
                "display_file": item["relative"],
                "size": item["size"],
                "analysis_mode": root.analysis_mode or "auto",
            }
            key = api._make_patch_id(record_data)
            if (
                runtime.job.request.get("patch_keys")
                and key not in runtime.job.request["patch_keys"]
            ):
                continue
            previous = dict(by_id.get(key) or {})
            if previous.get("locked") or previous.get("metadata_locked"):
                continue
            digest = fingerprint(
                [
                    root.id,
                    item["relative"],
                    item["size"],
                    item["modified"],
                    previous.get("manifest_updated_at"),
                ],
                runtime.settings,
            )
            if await cached(runtime, digest):
                await record(runtime, key, digest, "cached", "复用未变化补丁的配置")
                continue
            catalog = Catalog(config, runtime.job.actor_id, runtime)
            outcome, summary = "fallback", "智能分析未完成，使用原有补丁识别"
            try:
                documents = {}

                async def inspect(
                    args, root=root, source=source, item=item, documents=documents
                ):
                    data = await inspect_file(root, source, item, runtime.settings)
                    documents.update(data)
                    return data

                tools = catalog.tools()
                tools["inspect_patch"] = (
                    tool_spec(
                        "inspect_patch",
                        "Read the patch archive listing and installation documents",
                        object_schema({}),
                    ),
                    inspect,
                )
                data = await runtime.reason(
                    "patch",
                    {
                        "file": item["relative"],
                        "preferences": runtime.settings.patch_preferences,
                        "sources": [s.source_name for s in catalog.scrapers],
                    },
                    PatchSelection.model_json_schema(),
                    tools,
                )
                proposal = PatchSelection.model_validate(data)
                if proposal.candidate >= len(catalog.results):
                    raise ValueError()
                result = catalog.results[proposal.candidate]
                app_id = (
                    result.source_id
                    if result.source_name == "steam"
                    else result.external_ids.get("steam")
                )
                if not app_id or not str(app_id).isdigit():
                    raise ValueError("缺少经过验证的 Steam ID")
                if previous.get("manifest_status") == "confirmed" and str(
                    previous.get("app_id") or ""
                ) != str(app_id):
                    await record(
                        runtime,
                        key,
                        digest,
                        "review",
                        "新匹配与已配置的游戏不一致，保留原配置",
                    )
                    continue
                name = result.title
                if runtime.settings.patch_steam_name:
                    from scan_patches import _steam_name_for_app_id

                    steam_name = await asyncio.to_thread(_steam_name_for_app_id, app_id)
                    name = steam_name or name
                record_data.update(
                    app_id=str(app_id),
                    game_name=name,
                    type=_guess_type(item["relative"], DEFAULT_TYPE_KEYWORDS),
                )
                summary = proposal.evidence
                src = relative_path(proposal.patch_dir, allow_empty=True)
                dest = relative_path(proposal.target_dir, allow_empty=True)
                text = "\n".join(d["text"] for d in documents.get("documents", []))
                entries = documents.get("tree", [])
                quoted = proposal.instruction_quote.strip()
                has_source = any(
                    e.get("type") == "file"
                    and (not src or e["path"].startswith(src + "/"))
                    for e in entries
                )
                if (
                    proposal.copy_only
                    and documents.get("complete")
                    and len(quoted) >= 12
                    and quoted in text
                    and has_source
                ):
                    if previous.get("manifest_status") != "confirmed":
                        record_data.update(
                            patch_dir=src,
                            target_dir=dest,
                            manifest_status="confirmed",
                            manifest_updated_at=datetime.utcnow().isoformat(),
                        )
                    outcome = "applied"
                else:
                    outcome = "review"
                    summary += "；复制目录依据不足，保持待配置"
            except AgentStopped:
                raise
            except Exception as exc:
                outcome, summary = fallback_details(exc)
                app_id = await asyncio.to_thread(
                    _guess_app_id, item["relative"], Path(item["path"]).name
                )
                app_id, name = await asyncio.to_thread(
                    _enrich_identity, app_id, Path(item["path"]).name
                )
                if app_id and runtime.settings.patch_steam_name:
                    from scan_patches import _steam_name_for_app_id

                    try:
                        name = (
                            await asyncio.to_thread(_steam_name_for_app_id, app_id)
                            or name
                        )
                    except Exception:
                        pass
                record_data.update(
                    app_id=app_id,
                    game_name=name,
                    type=_guess_type(item["relative"], DEFAULT_TYPE_KEYWORDS),
                )
            finally:
                await catalog.close()
            await runtime.check()
            # Re-read before applying so a manual configuration made during analysis wins.
            latest = {api._make_patch_id(p): p for p in api._load_all_patches(index)}
            if latest.get(key, {}) != previous:
                await record(
                    runtime, key, digest, "review", "分析期间补丁配置已变化，保留原配置"
                )
                continue
            merged = {**previous, **record_data}
            if previous.get("name_locked"):
                merged["game_name"] = previous.get("game_name", "")
            merged.setdefault("patch_dir", "")
            merged.setdefault("target_dir", "")
            merged.setdefault("manifest_status", "pending")
            latest[key] = merged
            target = index / "patches.json"
            temp = target.with_suffix(".agent.tmp")
            temp.write_text(
                json.dumps(
                    {"patches": list(latest.values())}, ensure_ascii=False, indent=2
                ),
                encoding="utf-8",
            )
            temp.replace(target)
            by_id[key] = merged
            digest = fingerprint(
                [
                    root.id,
                    item["relative"],
                    item["size"],
                    item["modified"],
                    merged.get("manifest_updated_at"),
                ],
                runtime.settings,
            )
            await record(runtime, key, digest, outcome, summary, {"patch": merged})


async def run_job(job_id):
    async with database._session_factory() as session:
        job = await session.get(AgentJob, job_id)
        config = load_config()
        try:
            with process_lock(
                scan_lock_path(config.data_path), blocking=False
            ) as acquired:
                if not acquired:
                    raise ValueError("扫描或恢复正在运行，请稍后重试")
                settings, revision = await load_settings(session)
                runtime = Runtime(session, job, settings, revision)
                await runtime.check()
                job.status = "running"
                await session.commit()
                if job.kind == "patch":
                    await patch_scan(runtime)
                else:
                    from api.settings import _load_scan_settings

                    _load_scan_settings(config)
                    if job.kind == "game":
                        query = select(RootDirectory)
                        if job.request.get("root_ids"):
                            query = query.where(
                                RootDirectory.id.in_(job.request["root_ids"])
                            )
                        for root in (await session.execute(query)).scalars().all():
                            await discover_root(runtime, root)
                    query = (
                        select(Game)
                        .where(Game.is_deleted.is_(False))
                        .options(selectinload(Game.company))
                    )
                    if job.kind == "game":
                        query = query.where(
                            Game.root_id.in_(
                                select(RootDirectory.id).where(
                                    RootDirectory.enable_batch_scrape.is_(True)
                                )
                            )
                        )
                    if job.request.get("root_ids"):
                        query = query.where(Game.root_id.in_(job.request["root_ids"]))
                    if job.request.get("game_ids"):
                        query = query.where(Game.id.in_(job.request["game_ids"]))
                    game_ids = [g.id for g in (await session.execute(query)).scalars()]
                    config.covers_path.mkdir(parents=True, exist_ok=True)
                    async with httpx.AsyncClient(
                        timeout=30, proxy=config.proxy or None, trust_env=False
                    ) as client:
                        for game_id in game_ids:
                            await runtime.check()
                            try:
                                game = (
                                    await session.execute(
                                        select(Game)
                                        .where(
                                            Game.id == game_id,
                                            Game.is_deleted.is_(False),
                                        )
                                        .options(selectinload(Game.company))
                                    )
                                ).scalar_one_or_none()
                                if game is None:
                                    continue
                                await scrape_game(runtime, game, client)
                            except AgentStopped:
                                raise
                            except Exception as exc:
                                await session.rollback()
                                await record(
                                    runtime,
                                    game_id,
                                    "",
                                    "review",
                                    f"条目处理失败（{type(exc).__name__}），可单独重试",
                                )
                job.status = "completed"
                job.message = "任务完成，明确结果已自动应用，请查看待处理项"
                budget_fallbacks = (
                    await session.execute(
                        select(func.count())
                        .select_from(AgentResult)
                        .where(
                            AgentResult.job_id == job_id,
                            AgentResult.status == "budget_fallback",
                        )
                    )
                ).scalar_one()
                if budget_fallbacks:
                    job.message = f"任务完成；{budget_fallbacks} 项因预算限制转入常规流程，不代表资料无法识别"
        except AgentStopped:
            await session.rollback()
            job.status = "cancelled"
            job.message = "任务已停止，已应用结果保留"
        except Exception as exc:
            await session.rollback()
            job.status = "failed"
            job.message = f"任务失败（{type(exc).__name__}），已完成结果保留，可重试"
            logger.warning(
                "Agent job failed: job=%s reason=%s", job_id, type(exc).__name__
            )
        job.finished_at = datetime.utcnow()
        await session.commit()


def launch(job_id):
    task = asyncio.create_task(run_job(job_id))
    _tasks[job_id] = task
    task.add_done_callback(lambda _: _tasks.pop(job_id, None))


async def scheduled_scan(config):
    from api.roots import _run_scan
    from api.settings import _mark_auto_scan
    from api.steam_patch import scan_patches_endpoint
    import time

    async with database._session_factory() as session:
        settings, _ = await load_settings(session)
        if not settings.enabled:
            return await _run_scan(config, update_last=True)
        if (
            settings.enabled
            and settings.model.strip()
            and settings.scheduled_game == "agent"
        ):
            active = (
                await session.execute(
                    select(AgentJob.id).where(
                        AgentJob.status.in_(["pending", "running"])
                    )
                )
            ).first()
            if active:
                return {"skipped": True}
            job = AgentJob(kind="game", request={}, status="pending")
            session.add(job)
            await session.commit()
            await run_job(job.id)
            _mark_auto_scan(config, time.time())
            result = {"agent": True}
        else:
            result = await _run_scan(config, update_last=True)
        if result.get("skipped"):
            return result
        if (
            settings.enabled
            and settings.model.strip()
            and settings.scheduled_patch == "agent"
        ):
            job = AgentJob(kind="patch", request={}, status="pending")
            session.add(job)
            await session.commit()
            await run_job(job.id)
        else:
            await scan_patches_endpoint(mode="merge", user=None, session=session)
        return result
