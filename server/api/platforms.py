"""Platform category management API."""

from __future__ import annotations

import logging

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel
from sqlalchemy import func, select, update
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from api.auth import get_current_user, require_admin
from config import load_config
from database import get_session
from models.game import Game, GameVersion, PlatformCategory, PlatformCategoryRule
from models.user import User
from schemas.common import MessageResponse
from services.platforms import (
    SYSTEM_CATEGORY_NAME,
    load_platform_rules,
    validate_category_name,
    validate_rule,
)
from utils.regex_patterns import match_platform

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/platforms", tags=["platforms"])


class PlatformRuleOut(BaseModel):
    id: int
    kind: str
    pattern: str
    sort_order: int


class PlatformCategoryOut(BaseModel):
    id: int
    name: str
    sort_order: int
    is_system: bool
    version_count: int = 0
    rules: list[PlatformRuleOut] = []


class PlatformCategoryCreate(BaseModel):
    name: str


class PlatformCategoryUpdate(BaseModel):
    name: str | None = None
    sort_order: int | None = None


class PlatformOrderUpdate(BaseModel):
    ids: list[int]


class PlatformRuleCreate(BaseModel):
    kind: str
    pattern: str


class PlatformRuleUpdate(BaseModel):
    kind: str | None = None
    pattern: str | None = None


class PlatformRuleOrderUpdate(BaseModel):
    ids: list[int]


class TestMatchRequest(BaseModel):
    filename: str


def _rule_out(rule: PlatformCategoryRule) -> PlatformRuleOut:
    return PlatformRuleOut(
        id=rule.id, kind=rule.kind, pattern=rule.pattern, sort_order=rule.sort_order
    )


def _sorted_rules(category: PlatformCategory) -> list[PlatformCategoryRule]:
    return sorted(category.rules, key=lambda item: (item.sort_order, item.id))


def _category_out(category: PlatformCategory, version_count: int) -> PlatformCategoryOut:
    return PlatformCategoryOut(
        id=category.id,
        name=category.name,
        sort_order=category.sort_order,
        is_system=bool(category.is_system),
        version_count=version_count,
        rules=[_rule_out(rule) for rule in _sorted_rules(category)],
    )


async def _load_category(session: AsyncSession, category_id: int) -> PlatformCategory:
    result = await session.execute(
        select(PlatformCategory)
        .options(selectinload(PlatformCategory.rules))
        .where(PlatformCategory.id == category_id)
    )
    category = result.scalar_one_or_none()
    if category is None:
        raise HTTPException(status_code=404, detail="分类不存在")
    return category


async def _version_counts(session: AsyncSession) -> dict[str, int]:
    rows = await session.execute(
        select(GameVersion.platform, func.count(GameVersion.id)).group_by(
            GameVersion.platform
        )
    )
    return {name: count for name, count in rows.all()}


async def _name_taken(
    session: AsyncSession, name: str, exclude_id: int | None = None
) -> bool:
    query = select(PlatformCategory.id).where(
        func.lower(PlatformCategory.name) == name.lower()
    )
    if exclude_id is not None:
        query = query.where(PlatformCategory.id != exclude_id)
    return (await session.execute(query)).scalar_one_or_none() is not None


async def _next_sort_order(session: AsyncSession) -> int:
    current = (
        await session.execute(
            select(func.max(PlatformCategory.sort_order)).where(
                PlatformCategory.is_system == False  # noqa: E712
            )
        )
    ).scalar()
    return (current or 0) + 1


@router.get("", response_model=list[PlatformCategoryOut])
async def list_platforms(
    user: User = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
):
    """List platform categories with version counts and detection rules."""
    result = await session.execute(
        select(PlatformCategory)
        .options(selectinload(PlatformCategory.rules))
        .order_by(
            PlatformCategory.is_system,
            PlatformCategory.sort_order,
            PlatformCategory.id,
        )
    )
    categories = result.scalars().all()
    counts = await _version_counts(session)
    return [
        _category_out(category, counts.get(category.name, 0))
        for category in categories
    ]


@router.post("", response_model=PlatformCategoryOut)
async def create_platform(
    body: PlatformCategoryCreate,
    user: User = Depends(require_admin),
    session: AsyncSession = Depends(get_session),
):
    """Create a custom platform category (admin only)."""
    try:
        name = validate_category_name(body.name)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    if name == SYSTEM_CATEGORY_NAME or await _name_taken(session, name):
        raise HTTPException(status_code=400, detail="分类名已存在")
    category = PlatformCategory(
        name=name, sort_order=await _next_sort_order(session), is_system=False
    )
    session.add(category)
    await session.commit()
    await session.refresh(category)
    logger.info("Platform category created: actor_id=%s name=%s", user.id, name)
    return PlatformCategoryOut(
        id=category.id,
        name=category.name,
        sort_order=category.sort_order,
        is_system=False,
        version_count=0,
        rules=[],
    )


@router.put("/order", response_model=MessageResponse)
async def reorder_platforms(
    body: PlatformOrderUpdate,
    user: User = Depends(require_admin),
    session: AsyncSession = Depends(get_session),
):
    """Persist the category order; system categories stay last (admin only)."""
    if not body.ids:
        return MessageResponse(message="顺序未变化")
    result = await session.execute(
        select(PlatformCategory).where(PlatformCategory.id.in_(body.ids))
    )
    categories = {category.id: category for category in result.scalars().all()}
    for index, category_id in enumerate(body.ids):
        category = categories.get(category_id)
        if category is None or category.is_system:
            continue
        category.sort_order = index
    await session.commit()
    return MessageResponse(message="顺序已更新")


@router.post("/test-match", response_model=dict)
async def test_match(
    body: TestMatchRequest,
    user: User = Depends(require_admin),
    session: AsyncSession = Depends(get_session),
):
    """Return the category a filename would be detected as (admin only)."""
    filename = (body.filename or "").strip()
    if not filename:
        raise HTTPException(status_code=400, detail="文件名不能为空")
    rules = await load_platform_rules(session, load_config())
    return {"category": match_platform(filename, rules), "rules": len(rules)}


@router.post("/reidentify", response_model=dict)
async def reidentify_platforms(
    user: User = Depends(require_admin),
    session: AsyncSession = Depends(get_session),
):
    """Re-run rule detection for every version of the library (admin only)."""
    rules = await load_platform_rules(session, load_config())
    result = await session.execute(
        select(GameVersion)
        .join(Game, Game.id == GameVersion.game_id)
        .where(Game.is_deleted == False)  # noqa: E712
    )
    versions = result.scalars().all()
    changed = 0
    for version in versions:
        detected = match_platform(version.filename or "", rules)
        if version.platform != detected:
            version.platform = detected
            changed += 1
    await session.commit()
    logger.info(
        "Platform categories reidentified: actor_id=%s changed=%s total=%s",
        user.id,
        changed,
        len(versions),
    )
    return {
        "message": f"已重新识别 {len(versions)} 个版本，其中 {changed} 个分类有变化",
        "changed": changed,
        "total": len(versions),
    }


@router.put("/{category_id}", response_model=PlatformCategoryOut)
async def update_platform(
    category_id: int,
    body: PlatformCategoryUpdate,
    user: User = Depends(require_admin),
    session: AsyncSession = Depends(get_session),
):
    """Rename or reorder a category; renames cascade to versions (admin only)."""
    category = await _load_category(session, category_id)
    if category.is_system:
        raise HTTPException(status_code=400, detail="系统分类不能修改")
    if body.name is not None:
        try:
            name = validate_category_name(body.name)
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc))
        if name != category.name:
            if await _name_taken(session, name, exclude_id=category.id):
                raise HTTPException(status_code=400, detail="分类名已存在")
            old_name = category.name
            category.name = name
            await session.execute(
                update(GameVersion)
                .where(GameVersion.platform == old_name)
                .values(platform=name)
            )
            logger.info(
                "Platform category renamed: actor_id=%s %s -> %s",
                user.id,
                old_name,
                name,
            )
    if body.sort_order is not None:
        category.sort_order = body.sort_order
    await session.commit()
    counts = await _version_counts(session)
    return _category_out(category, counts.get(category.name, 0))


@router.delete("/{category_id}", response_model=MessageResponse)
async def delete_platform(
    category_id: int,
    reassign_to_id: int | None = Query(default=None),
    user: User = Depends(require_admin),
    session: AsyncSession = Depends(get_session),
):
    """Delete a category; versions using it must be reassigned (admin only)."""
    category = await _load_category(session, category_id)
    if category.is_system:
        raise HTTPException(status_code=400, detail="系统分类不能删除")
    count = (
        await session.execute(
            select(func.count(GameVersion.id)).where(
                GameVersion.platform == category.name
            )
        )
    ).scalar() or 0
    target: PlatformCategory | None = None
    if count:
        if reassign_to_id is None:
            raise HTTPException(
                status_code=409,
                detail=f"还有 {count} 个版本使用「{category.name}」，请先选择替代分类",
            )
        target = await _load_category(session, reassign_to_id)
        if target.id == category.id:
            raise HTTPException(status_code=400, detail="替代分类不能是自身")
        await session.execute(
            update(GameVersion)
            .where(GameVersion.platform == category.name)
            .values(platform=target.name)
        )
    name = category.name
    await session.delete(category)
    await session.commit()
    logger.info(
        "Platform category deleted: actor_id=%s name=%s reassigned=%s",
        user.id,
        name,
        count,
    )
    message = f"已删除分类「{name}」"
    if count and target is not None:
        message += f"，{count} 个版本已改为「{target.name}」"
    return MessageResponse(message=message)


@router.get("/{category_id}/rules", response_model=list[PlatformRuleOut])
async def list_rules(
    category_id: int,
    user: User = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
):
    category = await _load_category(session, category_id)
    return [_rule_out(rule) for rule in _sorted_rules(category)]


@router.post("/{category_id}/rules", response_model=PlatformRuleOut)
async def create_rule(
    category_id: int,
    body: PlatformRuleCreate,
    user: User = Depends(require_admin),
    session: AsyncSession = Depends(get_session),
):
    """Add a detection rule to a category (admin only)."""
    category = await _load_category(session, category_id)
    if category.is_system:
        raise HTTPException(status_code=400, detail="未分类不支持匹配规则")
    try:
        kind, pattern = validate_rule(body.kind, body.pattern)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    next_order = max((rule.sort_order for rule in category.rules), default=-1) + 1
    rule = PlatformCategoryRule(
        category_id=category.id, kind=kind, pattern=pattern, sort_order=next_order
    )
    session.add(rule)
    await session.commit()
    await session.refresh(rule)
    logger.info(
        "Platform rule created: actor_id=%s category=%s kind=%s",
        user.id,
        category.name,
        kind,
    )
    return _rule_out(rule)


@router.put("/{category_id}/rules/order", response_model=MessageResponse)
async def reorder_rules(
    category_id: int,
    body: PlatformRuleOrderUpdate,
    user: User = Depends(require_admin),
    session: AsyncSession = Depends(get_session),
):
    category = await _load_category(session, category_id)
    if category.is_system:
        raise HTTPException(status_code=400, detail="未分类不支持匹配规则")
    rules = {rule.id: rule for rule in category.rules}
    for index, rule_id in enumerate(body.ids):
        rule = rules.get(rule_id)
        if rule is not None:
            rule.sort_order = index
    await session.commit()
    return MessageResponse(message="规则顺序已更新")


@router.put("/{category_id}/rules/{rule_id}", response_model=PlatformRuleOut)
async def update_rule(
    category_id: int,
    rule_id: int,
    body: PlatformRuleUpdate,
    user: User = Depends(require_admin),
    session: AsyncSession = Depends(get_session),
):
    category = await _load_category(session, category_id)
    if category.is_system:
        raise HTTPException(status_code=400, detail="未分类不支持匹配规则")
    rule = next((item for item in category.rules if item.id == rule_id), None)
    if rule is None:
        raise HTTPException(status_code=404, detail="规则不存在")
    try:
        kind, pattern = validate_rule(
            body.kind if body.kind is not None else rule.kind,
            body.pattern if body.pattern is not None else rule.pattern,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    rule.kind = kind
    rule.pattern = pattern
    await session.commit()
    return _rule_out(rule)


@router.delete("/{category_id}/rules/{rule_id}", response_model=MessageResponse)
async def delete_rule(
    category_id: int,
    rule_id: int,
    user: User = Depends(require_admin),
    session: AsyncSession = Depends(get_session),
):
    category = await _load_category(session, category_id)
    if category.is_system:
        raise HTTPException(status_code=400, detail="未分类不支持匹配规则")
    rule = next((item for item in category.rules if item.id == rule_id), None)
    if rule is None:
        raise HTTPException(status_code=404, detail="规则不存在")
    await session.delete(rule)
    await session.commit()
    return MessageResponse(message="规则已删除")
