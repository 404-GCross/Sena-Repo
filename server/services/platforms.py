"""Platform category helpers: rule loading, validation and name checks."""

from __future__ import annotations

import logging
import re

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from config import Config
from models.game import PlatformCategory, PlatformCategoryRule
from utils.regex_patterns import PlatformRule, RULE_KINDS, UNCATEGORIZED

logger = logging.getLogger(__name__)

SYSTEM_CATEGORY_NAME = UNCATEGORIZED
SYSTEM_CATEGORY_ORDER = 100000
MAX_CATEGORY_NAME_LENGTH = 32
MAX_RULE_PATTERN_LENGTH = 256


def normalize_category_name(name: str) -> str:
    return (name or "").strip()


def validate_category_name(name: str) -> str:
    value = normalize_category_name(name)
    if not value:
        raise ValueError("分类名不能为空")
    if len(value) > MAX_CATEGORY_NAME_LENGTH:
        raise ValueError(f"分类名不能超过 {MAX_CATEGORY_NAME_LENGTH} 个字符")
    if "," in value:
        raise ValueError("分类名不能包含逗号")
    return value


def validate_rule(kind: str, pattern: str) -> tuple[str, str]:
    kind_value = (kind or "").strip().lower()
    if kind_value not in RULE_KINDS:
        raise ValueError(f"规则类型必须是 {'/'.join(RULE_KINDS)}")
    pattern_value = (pattern or "").strip()
    if not pattern_value:
        raise ValueError("规则内容不能为空")
    if len(pattern_value) > MAX_RULE_PATTERN_LENGTH:
        raise ValueError(f"规则内容不能超过 {MAX_RULE_PATTERN_LENGTH} 个字符")
    if kind_value == "regex":
        try:
            re.compile(pattern_value)
        except re.error as exc:
            raise ValueError(f"正则表达式无效: {exc}") from exc
    return kind_value, pattern_value


async def load_platform_rules(
    session: AsyncSession, config: Config | None = None
) -> list[PlatformRule]:
    """Ordered detection rules: database categories first, then legacy config regex."""
    result = await session.execute(
        select(PlatformCategory, PlatformCategoryRule)
        .join(
            PlatformCategoryRule,
            PlatformCategoryRule.category_id == PlatformCategory.id,
        )
        .where(PlatformCategory.is_system == False)  # noqa: E712
        .order_by(
            PlatformCategory.sort_order,
            PlatformCategory.id,
            PlatformCategoryRule.sort_order,
            PlatformCategoryRule.id,
        )
    )
    rules = [
        PlatformRule(category=category.name, kind=rule.kind, pattern=rule.pattern)
        for category, rule in result.all()
    ]
    if config is None or not config.custom_regex:
        return rules
    known = {
        row[0]
        for row in (await session.execute(select(PlatformCategory.name))).all()
    }
    for item in config.custom_regex:
        pattern = (item.pattern or "").strip()
        category = normalize_category_name(item.platform)
        if not pattern or not category or category == SYSTEM_CATEGORY_NAME:
            continue
        if category not in known:
            logger.warning(
                "custom_regex targets unknown platform category: %s", category
            )
            continue
        rules.append(PlatformRule(category=category, kind="regex", pattern=pattern))
    return rules


async def ensure_category(
    session: AsyncSession, name: str
) -> PlatformCategory | None:
    """Return an existing category by name, creating it when missing."""
    value = normalize_category_name(name) or SYSTEM_CATEGORY_NAME
    existing = (
        await session.execute(
            select(PlatformCategory).where(PlatformCategory.name == value)
        )
    ).scalar_one_or_none()
    if existing is not None:
        return existing
    max_order = (
        await session.execute(
            select(func.max(PlatformCategory.sort_order)).where(
                PlatformCategory.is_system == False  # noqa: E712
            )
        )
    ).scalar() or 0
    category = PlatformCategory(
        name=value,
        sort_order=max_order + 1,
        is_system=value == SYSTEM_CATEGORY_NAME,
    )
    session.add(category)
    await session.flush()
    return category
