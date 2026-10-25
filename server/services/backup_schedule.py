"""Automatic backup settings: storage, validation and next-run calculation.

The schedule is calendar-based rather than a cron expression: pick one of four
modes, then the days and times that apply. Times are server-local.
"""

from __future__ import annotations

import json
import logging
import secrets
from datetime import datetime, time, timedelta
from pathlib import Path
from typing import Any

logger = logging.getLogger(__name__)

SETTINGS_NAME = "backup_settings.json"
MODES = ("hour", "day", "week", "month")
SCOPES = ("all", "library", "patch")
MAX_INTERVAL_HOURS = 720
MAX_RETENTION = 365
FAILURE_BASE_MINUTES = 15
FAILURE_MAX_MINUTES = 360
_SEARCH_DAYS = 400


def settings_path(config) -> Path:
    return Path(config.data_path or "/data") / SETTINGS_NAME


def default_settings() -> dict[str, Any]:
    return {
        "enabled": False,
        "mode": "day",
        "interval_hours": 24,
        "times": ["03:00"],
        "weekdays": [0],
        "monthdays": [1],
        "window": None,
        "scope": "all",
        "include_media": True,
        "retention": {"last": 7, "daily": 14, "weekly": 8, "monthly": 12},
        "skip_if_unchanged": True,
        "min_free_gb": 0,
        "next_run_at": 0,
        "last_run": 0,
        "last_error": "",
        "last_result": "",
        "last_file": "",
        "last_fingerprint": "",
        "failed_streak": 0,
    }


def _parse_hhmm(value: Any) -> time | None:
    if not isinstance(value, str):
        return None
    parts = value.strip().split(":")
    if len(parts) != 2:
        return None
    try:
        hour, minute = int(parts[0]), int(parts[1])
    except ValueError:
        return None
    if not 0 <= hour <= 23 or not 0 <= minute <= 59:
        return None
    return time(hour, minute)


def format_hhmm(value: time) -> str:
    return f"{value.hour:02d}:{value.minute:02d}"


def _positive_int(value: Any, default: int, *, low: int, high: int) -> int:
    try:
        parsed = int(value)
    except (TypeError, ValueError):
        return default
    if parsed < low:
        return default
    return min(high, parsed)


def _times(value: Any) -> list[str]:
    if not isinstance(value, list):
        return list(default_settings()["times"])
    cleaned: list[str] = []
    for item in value:
        parsed = _parse_hhmm(item)
        if parsed is None:
            continue
        text = format_hhmm(parsed)
        if text not in cleaned:
            cleaned.append(text)
    if not cleaned:
        return list(default_settings()["times"])
    return sorted(cleaned)


def _weekdays(value: Any) -> list[int]:
    if not isinstance(value, list):
        return list(default_settings()["weekdays"])
    days = sorted({int(item) for item in value if isinstance(item, int) or str(item).isdigit()})
    days = [day for day in days if 0 <= day <= 6]
    return days or [0]


def _monthdays(value: Any) -> list[int]:
    if not isinstance(value, list):
        return list(default_settings()["monthdays"])
    days = sorted({int(item) for item in value if isinstance(item, int) or str(item).isdigit()})
    days = [day for day in days if 1 <= day <= 31]
    return days or [1]


def _window(value: Any) -> dict[str, str] | None:
    if not isinstance(value, dict):
        return None
    start = _parse_hhmm(value.get("start"))
    end = _parse_hhmm(value.get("end"))
    if start is None or end is None or start == end:
        return None
    return {"start": format_hhmm(start), "end": format_hhmm(end)}


def _retention(value: Any) -> dict[str, int]:
    source = value if isinstance(value, dict) else {}
    defaults = default_settings()["retention"]
    return {
        "last": _positive_int(source.get("last"), defaults["last"], low=0, high=100),
        "daily": _positive_int(source.get("daily"), defaults["daily"], low=0, high=MAX_RETENTION),
        "weekly": _positive_int(source.get("weekly"), defaults["weekly"], low=0, high=MAX_RETENTION),
        "monthly": _positive_int(source.get("monthly"), defaults["monthly"], low=0, high=MAX_RETENTION),
    }


def normalise_settings(raw: Any) -> dict[str, Any]:
    """Return a fully typed settings dict; unknown or invalid values fall back."""
    base = default_settings()
    if not isinstance(raw, dict):
        return base

    mode = raw.get("mode")
    base["mode"] = mode if mode in MODES else base["mode"]
    base["enabled"] = bool(raw.get("enabled", base["enabled"]))
    base["interval_hours"] = _positive_int(
        raw.get("interval_hours"), base["interval_hours"], low=1, high=MAX_INTERVAL_HOURS
    )
    base["times"] = _times(raw.get("times"))
    base["weekdays"] = _weekdays(raw.get("weekdays"))
    base["monthdays"] = _monthdays(raw.get("monthdays"))
    base["window"] = _window(raw.get("window"))

    scope = raw.get("scope")
    base["scope"] = scope if scope in SCOPES else base["scope"]
    base["include_media"] = bool(raw.get("include_media", base["include_media"]))
    base["retention"] = _retention(raw.get("retention"))
    base["skip_if_unchanged"] = bool(
        raw.get("skip_if_unchanged", base["skip_if_unchanged"])
    )
    try:
        base["min_free_gb"] = max(0.0, float(raw.get("min_free_gb") or 0))
    except (TypeError, ValueError):
        base["min_free_gb"] = 0.0

    for key in ("next_run_at", "last_run"):
        try:
            base[key] = float(raw.get(key) or 0)
        except (TypeError, ValueError):
            base[key] = 0.0
    for key in ("last_error", "last_result", "last_file", "last_fingerprint"):
        value = raw.get(key)
        base[key] = value if isinstance(value, str) else ""
    base["failed_streak"] = _positive_int(raw.get("failed_streak"), 0, low=0, high=1000)
    return base


def load_backup_settings(config) -> dict[str, Any]:
    path = settings_path(config)
    if not path.is_file():
        return default_settings()
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        logger.warning(
            "Backup schedule unreadable; automatic backups stay disabled: file=%s error=%s",
            path.name,
            type(exc).__name__,
        )
        return default_settings()
    return normalise_settings(data)


def save_backup_settings(config, settings: dict[str, Any]) -> dict[str, Any]:
    payload = normalise_settings(settings)
    path = settings_path(config)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = path.with_name(f".{path.name}.{secrets.token_hex(3)}.tmp")
    tmp_path.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    tmp_path.replace(path)
    return payload


def update_backup_settings(config, changes: dict[str, Any]) -> dict[str, Any]:
    """Merge a partial update, recompute the next run and persist."""
    current = load_backup_settings(config)
    merged = dict(current)
    for key, value in changes.items():
        if key in ("next_run_at", "last_run", "last_error", "last_result",
                   "last_file", "last_fingerprint", "failed_streak"):
            continue  # runtime state is not client editable
        merged[key] = value
    normalised = normalise_settings(merged)
    normalised["next_run_at"] = (
        compute_next_run(normalised, datetime.now()).timestamp()
        if normalised["enabled"]
        else 0
    )
    return save_backup_settings(config, normalised)


def _apply_window(
    moment: datetime, window: dict[str, str] | None, now: datetime
) -> datetime:
    """Move a moment outside the allowed window to the window start of that day."""
    if not window:
        return moment
    start = _parse_hhmm(window.get("start"))
    end = _parse_hhmm(window.get("end"))
    if start is None or end is None or start == end:
        return moment
    current = moment.time()
    if start < end:
        inside = start <= current <= end
    else:
        # Window crosses midnight, e.g. 22:00 → 06:00.
        inside = current >= start or current <= end
    if inside:
        return moment

    candidate = datetime.combine(moment.date(), start)
    if candidate <= now:
        candidate = datetime.combine(moment.date() + timedelta(days=1), start)
    return candidate


def compute_next_run(
    settings: dict[str, Any], now: datetime, *, base: datetime | None = None
) -> datetime:
    """First scheduled moment strictly after `now`."""
    if settings.get("mode") == "hour":
        start = base or now
        candidate = start + timedelta(
            hours=_positive_int(
                settings.get("interval_hours"), 24, low=1, high=MAX_INTERVAL_HOURS
            )
        )
        if candidate <= now:
            candidate = now + timedelta(minutes=1)
        return _apply_window(candidate, settings.get("window"), now)

    times = [parsed for parsed in (_parse_hhmm(t) for t in settings.get("times") or []) if parsed]
    if not times:
        times = [time(3, 0)]
    weekdays = {day for day in settings.get("weekdays") or [0]}
    monthdays = {day for day in settings.get("monthdays") or [1]}
    mode = settings.get("mode")

    for offset in range(_SEARCH_DAYS):
        day = (now + timedelta(days=offset)).date()
        if mode == "week" and day.weekday() not in weekdays:
            continue
        if mode == "month" and day.day not in monthdays:
            continue
        for moment in (datetime.combine(day, item) for item in sorted(times)):
            if moment > now:
                return _apply_window(moment, settings.get("window"), now)
    return now + timedelta(days=1)


def is_due(settings: dict[str, Any], now: datetime) -> bool:
    if not settings.get("enabled"):
        return False
    next_run = float(settings.get("next_run_at") or 0)
    return next_run > 0 and now.timestamp() >= next_run


def record_success(
    settings: dict[str, Any],
    *,
    now: datetime,
    file_name: str,
    fingerprint: str,
) -> dict[str, Any]:
    settings["last_run"] = now.timestamp()
    settings["last_result"] = "ok"
    settings["last_file"] = file_name
    settings["last_fingerprint"] = fingerprint
    settings["last_error"] = ""
    settings["failed_streak"] = 0
    settings["next_run_at"] = compute_next_run(settings, now, base=now).timestamp()
    return settings


def record_skip(
    settings: dict[str, Any],
    *,
    now: datetime,
    reason: str,
    fingerprint: str | None = None,
    delay_minutes: int = 0,
) -> dict[str, Any]:
    settings["last_result"] = reason
    if fingerprint is not None:
        settings["last_fingerprint"] = fingerprint
    if delay_minutes:
        settings["next_run_at"] = (now + timedelta(minutes=delay_minutes)).timestamp()
    else:
        settings["last_run"] = now.timestamp()
        settings["next_run_at"] = compute_next_run(settings, now, base=now).timestamp()
    return settings


def record_failure(
    settings: dict[str, Any], *, now: datetime, message: str
) -> dict[str, Any]:
    streak = int(settings.get("failed_streak") or 0) + 1
    delay = min(FAILURE_BASE_MINUTES * (2 ** (streak - 1)), FAILURE_MAX_MINUTES)
    settings["failed_streak"] = streak
    settings["last_result"] = "error"
    settings["last_error"] = message[:300]
    settings["last_run"] = now.timestamp()
    settings["next_run_at"] = (now + timedelta(minutes=delay)).timestamp()
    return settings


def iso_from_ts(value: Any) -> str | None:
    try:
        stamp = float(value or 0)
    except (TypeError, ValueError):
        return None
    if stamp <= 0:
        return None
    return datetime.fromtimestamp(stamp).replace(microsecond=0).isoformat()
