"""Steam patch rule and type keyword export helpers shared by the backup commands."""

from __future__ import annotations

import copy
import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from cli.common import fail


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

def utc_timestamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")


def utc_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def patch_index_path(config) -> Path:
    return Path(config.data_path or "/data") / "steam_patch_index" / "patches.json"


def keywords_path(config) -> Path:
    return Path(config.data_path or "/data") / "steam_patch_index" / "patch_type_keywords.json"


def read_json(path: Path) -> dict[str, Any]:
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


def write_json(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = path.with_name(f".{path.name}.tmp")
    tmp_path.write_text(
        json.dumps(data, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    tmp_path.replace(path)


def load_patch_index(path: Path) -> dict[str, Any]:
    data = read_json(path)
    patches = data.get("patches")
    if not isinstance(patches, list):
        fail(f"补丁索引格式错误，缺少 patches 数组: {path}", 3)
    return data


def normalise_keywords(value: Any) -> dict[str, list[str]] | None:
    """Return a cleaned keyword map, or None when the payload cannot be trusted."""
    if not isinstance(value, dict) or not value:
        return None
    cleaned: dict[str, list[str]] = {}
    for group, words in value.items():
        if not isinstance(group, str) or not group.strip() or group.startswith("_"):
            continue
        if not isinstance(words, list):
            return None
        entries: list[str] = []
        for word in words:
            if not isinstance(word, str):
                return None
            text = word.strip()
            if text and text not in entries:
                entries.append(text)
        cleaned[group] = entries
    return cleaned or None


def read_keywords(path: Path) -> tuple[dict[str, list[str]] | None, str | None]:
    """Return (keywords, note); note explains why keywords are unavailable."""
    if not path.is_file():
        return None, f"未找到 {path.name}，不含关键词"
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        return None, f"{path.name} 无法读取（{exc}），不含关键词"
    keywords = normalise_keywords(data)
    if keywords is None:
        return None, f"{path.name} 结构不符合预期，不含关键词"
    return keywords, None


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


def rule_entries(patches: list[Any]) -> list[dict[str, Any]]:
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


def preview_restore(
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
