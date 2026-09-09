"""Steam patch rule backup and restore commands for senacli."""

from __future__ import annotations

import copy
import json
import shutil
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from cli.common import confirm, echo, fail, is_interactive, load_environment_file


RULE_FIELDS = (
    "app_id",
    "game_name",
    "label",
    "type",
    "patch_dir",
    "target_dir",
    "manifest_status",
    "manifest_updated_at",
)

RULE_DEFAULTS = {
    "app_id": None,
    "game_name": "",
    "label": "",
    "type": "misc",
    "patch_dir": "",
    "target_dir": "",
    "manifest_status": "pending",
    "manifest_updated_at": None,
}


def _utc_timestamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")


def _utc_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _load_server_config():
    load_environment_file()
    from config import load_config

    return load_config()


def _patch_index_path(config) -> Path:
    return Path(config.data_path or "/data") / "steam_patch_index" / "patches.json"


def _backup_dir(config) -> Path:
    return Path(config.data_path or "/data") / "backups" / "steam-patch-rules"


def _default_backup_path(config) -> Path:
    return _backup_dir(config) / f"sena-steam-patch-rules-{_utc_timestamp()}.json"


def _resolve_backup_output(args, config) -> Path:
    directory = getattr(args, "directory", None)
    output = getattr(args, "output", None)
    if directory and output:
        fail("不能同时指定备份目录和 -o 输出文件", 2)
    if directory:
        backup_dir = Path(directory).expanduser()
        if backup_dir.suffix.lower() == ".json":
            fail("backup 后面的路径表示目录；指定文件请使用 -o", 2)
        return backup_dir / f"sena-steam-patch-rules-{_utc_timestamp()}.json"
    if output:
        output_path = Path(output).expanduser()
        if output_path.exists() and output_path.is_dir():
            return output_path / f"sena-steam-patch-rules-{_utc_timestamp()}.json"
        return output_path
    return _default_backup_path(config)


def _read_json(path: Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        fail(f"文件不存在: {path}", 3)
    except json.JSONDecodeError as exc:
        fail(f"JSON 格式错误: {path} ({exc})", 3)
    except OSError as exc:
        fail(f"读取文件失败: {path} ({exc})", 3)
    if not isinstance(data, dict):
        fail(f"JSON 顶层必须是对象: {path}", 3)
    return data


def _write_json(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = path.with_name(f".{path.name}.tmp")
    tmp_path.write_text(
        json.dumps(data, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    tmp_path.replace(path)


def _load_patch_index(path: Path) -> dict[str, Any]:
    data = _read_json(path)
    patches = data.get("patches")
    if not isinstance(patches, list):
        fail(f"补丁索引格式错误，缺少 patches 数组: {path}", 3)
    return data


def _norm_text(value: Any) -> str:
    return str(value or "").strip()


def _norm_path(value: Any) -> str:
    text = _norm_text(value).replace("\\", "/")
    return text.rstrip("/") if text != "/" else text


def _source_id_text(value: Any) -> str:
    text = _norm_text(value)
    return "" if text.lower() in {"none", "null"} else text


def _int_or_zero(value: Any) -> int:
    try:
        return int(value or 0)
    except (TypeError, ValueError):
        return 0


def _file_name_from_identity(identity: dict[str, Any]) -> str:
    explicit = _norm_text(identity.get("file_name"))
    if explicit:
        return explicit
    for key in ("display_file", "source_path", "file", "relative_path"):
        value = _norm_path(identity.get(key))
        if value:
            return value.rsplit("/", 1)[-1]
    return ""


def _identity_from_patch(patch: dict[str, Any]) -> dict[str, Any]:
    return {
        "patch_id": _norm_text(patch.get("patch_id")),
        "source_type": _norm_text(patch.get("source_type") or "local"),
        "source_id": patch.get("source_id"),
        "source_name": _norm_text(patch.get("source_name")),
        "file": _norm_path(patch.get("file")),
        "source_path": _norm_path(patch.get("source_path")),
        "display_file": _norm_path(patch.get("display_file")),
        "relative_path": _norm_path(patch.get("display_file") or patch.get("file")),
        "file_name": _file_name_from_identity(patch),
        "size": _int_or_zero(patch.get("size")),
    }


def _rule_from_patch(patch: dict[str, Any]) -> dict[str, Any]:
    return {field: patch.get(field, RULE_DEFAULTS[field]) for field in RULE_FIELDS}


def _valid_app_id(value: Any) -> bool:
    text = _norm_text(value)
    return bool(text and text.lower() not in {"none", "null", "0"})


def _has_rule(patch: dict[str, Any]) -> bool:
    if _valid_app_id(patch.get("app_id")):
        return True
    if _norm_text(patch.get("label")):
        return True
    if _norm_text(patch.get("patch_dir")) or _norm_text(patch.get("target_dir")):
        return True
    if _norm_text(patch.get("manifest_status")).lower() == "confirmed":
        return True
    patch_type = _norm_text(patch.get("type")).lower()
    return bool(patch_type and patch_type != "misc")


def _rule_entries(patches: list[Any]) -> list[dict[str, Any]]:
    entries: list[dict[str, Any]] = []
    for patch in patches:
        if not isinstance(patch, dict) or not _has_rule(patch):
            continue
        entries.append(
            {
                "patch_identity": _identity_from_patch(patch),
                "rule": _rule_from_patch(patch),
            }
        )
    return entries


def _key_candidates(identity: dict[str, Any]) -> list[tuple[str, ...]]:
    source_type = _norm_text(identity.get("source_type") or "local")
    source_id = _source_id_text(identity.get("source_id"))
    file_path = _norm_path(identity.get("file"))
    source_path = _norm_path(identity.get("source_path"))
    display_file = _norm_path(identity.get("display_file") or identity.get("relative_path"))
    file_name = _file_name_from_identity(identity).lower()
    size = str(_int_or_zero(identity.get("size")))

    candidates: list[tuple[str, ...]] = []
    if file_path:
        candidates.append(("source-file", source_type, source_id, file_path))
        candidates.append(("file", file_path))
    if source_path:
        candidates.append(("source-path", source_type, source_id, source_path))
        candidates.append(("source-path-only", source_path))
    if display_file and size != "0":
        candidates.append(("display-size", source_type, display_file, size))
    if file_name and size != "0":
        candidates.append(("name-size", file_name, size))

    result: list[tuple[str, ...]] = []
    seen: set[tuple[str, ...]] = set()
    for candidate in candidates:
        if candidate in seen:
            continue
        seen.add(candidate)
        result.append(candidate)
    return result


def _build_match_index(patches: list[Any]) -> dict[tuple[str, ...], list[int]]:
    index: dict[tuple[str, ...], list[int]] = {}
    for item_index, patch in enumerate(patches):
        if not isinstance(patch, dict):
            continue
        for key in _key_candidates(_identity_from_patch(patch)):
            index.setdefault(key, []).append(item_index)
    return index


def _normalise_backup_rule(item: Any) -> tuple[dict[str, Any], dict[str, Any]] | None:
    if not isinstance(item, dict):
        return None
    identity = item.get("patch_identity")
    rule = item.get("rule")
    if not isinstance(identity, dict) or not isinstance(rule, dict):
        return None
    return identity, rule


def _clear_rule_fields(patch: dict[str, Any]) -> None:
    for field, value in RULE_DEFAULTS.items():
        patch[field] = value


def _apply_rule(patch: dict[str, Any], rule: dict[str, Any]) -> bool:
    before = {field: patch.get(field) for field in RULE_FIELDS}
    for field in RULE_FIELDS:
        if field in rule:
            patch[field] = rule[field]
    after = {field: patch.get(field) for field in RULE_FIELDS}
    return before != after


def _preview_restore(
    current_patches: list[Any],
    backup_rules: list[Any],
    *,
    replace: bool,
) -> tuple[list[Any], dict[str, Any]]:
    patches = copy.deepcopy(current_patches)
    match_index = _build_match_index(current_patches)
    if replace:
        for patch in patches:
            if isinstance(patch, dict):
                _clear_rule_fields(patch)

    imported = 0
    changed = 0
    skipped = 0
    conflicts: list[str] = []
    unmatched: list[str] = []

    for item in backup_rules:
        normalised = _normalise_backup_rule(item)
        if normalised is None:
            skipped += 1
            continue
        identity, rule = normalised
        label = _norm_path(identity.get("file") or identity.get("source_path") or identity.get("display_file"))
        if not label:
            label = _file_name_from_identity(identity) or "<unknown>"

        matched_indexes: list[int] = []
        conflict_key: tuple[str, ...] | None = None
        for key in _key_candidates(identity):
            indexes = sorted(set(match_index.get(key, [])))
            if len(indexes) == 1:
                matched_indexes = indexes
                break
            if len(indexes) > 1:
                conflict_key = key
                break

        if not matched_indexes:
            if conflict_key is not None:
                conflicts.append(label)
            else:
                unmatched.append(label)
            continue

        target = patches[matched_indexes[0]]
        if not isinstance(target, dict):
            skipped += 1
            continue
        if _apply_rule(target, rule):
            changed += 1
        imported += 1

    return patches, {
        "imported": imported,
        "changed": changed,
        "skipped": skipped,
        "conflicts": conflicts,
        "unmatched": unmatched,
        "total": len(backup_rules),
        "replace": replace,
    }


def cmd_backup(args) -> int:
    config = _load_server_config()
    index_path = _patch_index_path(config)
    if not index_path.is_file():
        fail(f"补丁索引不存在，请先扫描补丁库: {index_path}", 3)

    index_data = _load_patch_index(index_path)
    rules = _rule_entries(index_data["patches"])
    output = _resolve_backup_output(args, config)

    backup_data = {
        "schema_version": 1,
        "kind": "steam_patch_rules",
        "app": "Sena-Repo",
        "exported_at": _utc_iso(),
        "source": {
            "index_path": str(index_path),
        },
        "count": len(rules),
        "rules": rules,
    }
    _write_json(output, backup_data)
    echo(f"已导出 Steam 补丁匹配规则: {output}")
    echo(f"规则数量: {len(rules)}")
    return 0


def cmd_restore(args) -> int:
    config = _load_server_config()
    index_path = _patch_index_path(config)
    if not index_path.is_file():
        fail(f"补丁索引不存在，请先扫描补丁库: {index_path}", 3)

    backup_path = Path(args.file).expanduser()
    backup_data = _read_json(backup_path)
    if backup_data.get("kind") != "steam_patch_rules":
        fail("备份文件类型不正确，不是 Steam 补丁规则备份", 3)
    if backup_data.get("schema_version") != 1:
        fail(f"不支持的备份版本: {backup_data.get('schema_version')}", 3)
    backup_rules = backup_data.get("rules")
    if not isinstance(backup_rules, list):
        fail("备份文件格式错误，缺少 rules 数组", 3)

    index_data = _load_patch_index(index_path)
    restored_patches, stats = _preview_restore(
        index_data["patches"],
        backup_rules,
        replace=bool(args.replace),
    )
    echo("Steam 补丁规则恢复预览")
    echo(f"可恢复: {stats['imported']}")
    echo(f"会变更: {stats['changed']}")
    echo(f"无效条目: {stats['skipped']}")
    echo(f"冲突: {len(stats['conflicts'])}")
    echo(f"未匹配: {len(stats['unmatched'])}")
    if stats["conflicts"]:
        echo("冲突示例:")
        for item in stats["conflicts"][:5]:
            echo(f"  - {item}")
    if stats["unmatched"]:
        echo("未匹配示例:")
        for item in stats["unmatched"][:5]:
            echo(f"  - {item}")

    if not args.yes:
        if not is_interactive():
            fail("非交互恢复需要加 -y", 2)
        if not confirm("继续恢复 Steam 补丁匹配规则？"):
            echo("已取消")
            return 130

    safety_path = _backup_dir(config) / f"patches-before-restore-{_utc_timestamp()}.json"
    safety_path.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(index_path, safety_path)
    index_data["patches"] = restored_patches
    _write_json(index_path, index_data)
    echo(f"已恢复 Steam 补丁匹配规则: {index_path}")
    echo(f"恢复前索引备份: {safety_path}")
    return 0
