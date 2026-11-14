"""Resolve displayed build versions independently of the next update channel."""

from __future__ import annotations

import os
import re

_VERSION = re.compile(
    r"v?([0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?"
    r"(?:\+[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?)"
)
_SHA = re.compile(r"[0-9a-f]{7,64}")
_DEV_VERSION = re.compile(r"dev-[0-9a-f]{7,64}")


def project_version(value: str) -> str:
    value = value.strip()
    match = _VERSION.fullmatch(value) if len(value) <= 128 else None
    return match.group(1) if match else ""


def source_version(ref: str, sha: str) -> str:
    ref, sha = ref.strip(), sha.strip()
    if ref.startswith("v") and (version := project_version(ref)):
        return f"v{version}"
    if _SHA.fullmatch(sha):
        return f"dev-{sha[:7]}"
    return "未知"


def installed_version(metadata: dict[str, str]) -> str:
    reported = os.environ.get("SENA_VERSION", "").strip()
    if reported in {"dev", "test"} or _DEV_VERSION.fullmatch(reported):
        return reported
    if version := project_version(reported):
        return f"v{version}"
    # SOURCE_VERSION is only a release baseline; SOURCE_CHANNEL is future policy.
    return source_version(
        metadata.get("SOURCE_REF", ""), metadata.get("SOURCE_SHA", "")
    )
