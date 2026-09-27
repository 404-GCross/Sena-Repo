"""Rule-based platform category detection for archive filenames."""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Sequence

UNCATEGORIZED = "未分类"
RULE_KINDS = ("keyword", "regex")


@dataclass(frozen=True)
class PlatformRule:
    category: str
    kind: str
    pattern: str


def rule_matches(rule: PlatformRule, filename: str, lowered: str | None = None) -> bool:
    """Check a single rule against a filename (case-insensitive)."""
    if rule.kind == "keyword":
        haystack = lowered if lowered is not None else filename.lower()
        return bool(rule.pattern) and rule.pattern.lower() in haystack
    try:
        return re.search(rule.pattern, filename, re.IGNORECASE) is not None
    except re.error:
        return False


def match_platform(filename: str, rules: Sequence[PlatformRule]) -> str:
    """Return the first matching category name, or 未分类 when nothing matches."""
    lowered = filename.lower()
    for rule in rules:
        if rule_matches(rule, filename, lowered):
            return rule.category
    return UNCATEGORIZED
