from __future__ import annotations

from collections import Counter, defaultdict
from pathlib import PureWindowsPath

from sqlalchemy import func, select

from models.agent import AgentJob, AgentResult
from models.game import Game


REVIEW_STATUSES = {
    "review", "fallback", "partial", "unmatched", "budget_fallback", "model_fallback",
    "validation_fallback", "config_fallback", "source_fallback", "nsfw_unknown",
}
PAGE_SIZE = 30


def _is_item(job, row):
    if row.kind:
        return row.kind in {"game", "patch"}
    if job.kind == "patch":
        return row.key.startswith("sp_") or row.patch_name is not None
    if not row.key.isdecimal():
        return False
    if job.kind == "scrape" or row.game_id or row.status.startswith("nsfw_"):
        return True
    # Old game jobs also used numeric root IDs as keys for discovery records.
    return row.status == "applied" or row.summary.startswith(("复用未变化条目", "条目处理失败", "分析期间条目已修改", "条目已锁定"))


def _outcome(records, active):
    main = next((r for r in reversed(records) if not (r.ignored_status or r.status).startswith("nsfw_")), None)
    image = next((r for r in reversed(records) if (r.ignored_status or r.status).startswith("nsfw_")), None)
    if main is None:
        return "waiting" if active else "unfinished"
    if (main.status in REVIEW_STATUSES and not main.fallback_ok) or (image and image.status == "nsfw_unknown"):
        return "failed"
    return "ignored" if main.status == "ignored" else "success"


class ItemIndex:
    def __init__(self, job, plan, rows):
        self.active = job.status in {"pending", "running"}
        self.current = job.current_item if self.active else None
        self.has_plan = plan is not None
        requested = (job.request or {}).get("patch_keys" if job.kind == "patch" else "game_ids") or []
        self.names = dict(plan) if self.has_plan else {str(key): "" for key in requested}
        self.logs = defaultdict(list)
        self.preparation = []
        for row in rows:
            if not _is_item(job, row):
                self.preparation.append(row)
                continue
            self.logs[row.key].append(row)
            name = row.name or row.patch_name
            if name:
                self.names[row.key] = name
            else:
                self.names.setdefault(row.key, "")
        self.states = {key: _outcome(self.logs[key], self.active) for key in self.names}
        if self.current and self.current.get("kind") in {"game", "patch"}:
            key = self.current["key"]
            self.names[key] = self.current["name"]
            self.states[key] = "scanning"
        self.counts = Counter(self.states.values())
        self.unfinished = [key for key, state in self.states.items() if state in {"failed", "unfinished"}]
        self.restart_preparation = not self.has_plan and not self.states and job.status in {"interrupted", "cancelled", "failed"}


async def item_index(session, job):
    plan = await session.scalar(select(AgentJob.item_plan).where(AgentJob.id == job.id))
    r = AgentResult
    rows = (await session.execute(select(
        r.id, r.key, r.status, func.substr(r.summary, 1, 40).label("summary"), r.data["item_kind"].as_string().label("kind"),
        r.data["name"].as_string().label("name"), r.data["game_id"].as_integer().label("game_id"),
        r.data[("patch", "game_name")].as_string().label("patch_name"),
        r.data["fallback_completed"].as_boolean().label("fallback_ok"),
        r.data["ignored_status"].as_string().label("ignored_status"),
    ).where(r.job_id == job.id).order_by(r.id))).all()
    return ItemIndex(job, plan, rows)


def _brief(records, state):
    if state in ("waiting", "unfinished", "scanning", "ignored"):
        return {"waiting": "等待开始", "unfinished": "未完成，未计入失败", "scanning": "正在分析", "ignored": "已忽略"}[state]
    main = next((r for r in reversed(records) if not (r.data.get("ignored_status") or r.status).startswith("nsfw_")), None)
    if main is None:
        return "尚无最终结果"
    data = main.data or {}
    parts = []
    cover = data.get("cover_decision") or {}
    if cover.get("saved") is not None:
        orientation = cover.get("orientation")
        if orientation == "landscape" or "横版回退" in (cover.get("reason") or ""):
            parts.append("已用横版封面")
        elif orientation == "portrait" or cover.get("policy") == "work-edition-portrait-v2":
            parts.append({"zh": "已补中文竖封", "other": "已补原语言竖封"}.get(cover.get("language"), "已补竖版封面"))
        else:
            parts.append("已保存封面")
    elif cover:
        parts.extend(["资料已处理", "封面未写入" if cover.get("selected") is not None else "未找到匹配封面"])
    if data.get("background_failed"):
        parts.append("背景未写入")
    if not parts:
        if data.get("fallback_completed"):
            parts.append("常规刮削已补全资料")
        elif main.status == "applied":
            parts.append("补丁配置已应用" if data.get("patch") else "资料已应用")
        elif main.status == "cached":
            parts.append("已复用上次结果")
        elif data.get("patch") and main.status == "review":
            parts.append("补丁安装配置待确认")
        else:
            brief = {
                "budget_fallback": "模型预算已用尽，资料待核实", "model_fallback": "模型未完成识别，资料待核实",
                "source_fallback": "资料源异常，结果待核实", "validation_fallback": "匹配依据不足",
                "config_fallback": "配置已变更，结果待核实", "unmatched": "未匹配到作品",
            }.get(main.status)
            parts.append(brief or main.summary[:80])
    image = next((r for r in reversed(records) if (r.data.get("ignored_status") or r.status).startswith("nsfw_")), None)
    if image and image.status == "nsfw_unknown" and state == "failed":
        parts.append("图片尺度未确定")
    return " · ".join(parts)


async def item_page(session, job, bucket, offset):
    index = await item_index(session, job)
    states, counts = index.states, index.counts
    if bucket == "scanning" and not index.active:
        bucket = "failed" if counts["failed"] else "success"
        offset = 0
    order = {"scanning": 0, "failed": 1, "unfinished": 2, "ignored": 3, "success": 4, "waiting": 5}
    if bucket == "preparation":
        keys = [str(r.id) for r in index.preparation]
    elif bucket == "all":
        keys = sorted(states, key=lambda key: order[states[key]])
    else:
        keys = [key for key, state in states.items() if state == bucket]
    offset = min(max(0, offset), (max(len(keys) - 1, 0) // PAGE_SIZE) * PAGE_SIZE)
    page = keys[offset:offset + PAGE_SIZE]
    ids = [int(key) for key in page] if bucket == "preparation" else [r.id for key in page for r in index.logs[key]]
    records = defaultdict(list)
    for start in range(0, len(ids), 500):
        for r in await session.scalars(select(AgentResult).where(AgentResult.id.in_(ids[start:start+500])).order_by(AgentResult.id)):
            records[str(r.id) if bucket == "preparation" else r.key].append(r)
    unknown = [int(k) for k in page if k.isdecimal() and len(k) < 19 and not index.names.get(k)]
    names = {}
    if unknown and bucket != "preparation" and job.kind != "patch":
        names = {str(i): n for i, n in await session.execute(select(Game.id, Game.name).where(Game.id.in_(unknown)))}
    items = []
    for key in page:
        rows = records[key]
        if bucket == "preparation":
            row = rows[0]
            state = "success"
            if row.status == "ignored":
                state = "ignored"
            elif row.status in REVIEW_STATUSES and not row.data.get("fallback_completed"):
                state = "failed"
            name, brief = row.key, row.summary
        else:
            state = states[key]
            name = index.names[key] or names.get(key)
            if not name and rows and job.kind == "patch":
                name = PureWindowsPath((rows[-1].data.get("patch") or {}).get("display_file") or "").name
            name = name or (f"补丁 {key}" if job.kind == "patch" else f"游戏 #{key}")
            brief = _brief(rows, state)
            if state == "scanning" and index.current.get("stage"):
                brief = index.current["stage"]
        items.append({"key": key, "name": name, "state": state, "brief": brief, "records": [
            {"id": r.id, "key": r.key, "status": r.status, "summary": r.summary, "data": r.data} for r in rows
        ]})
    prep_failed = sum(r.status in REVIEW_STATUSES and not r.fallback_ok for r in index.preparation)
    return {
        "items": items,
        "bucket": bucket,
        "offset": offset,
        "has_more": offset + PAGE_SIZE < len(keys),
        "page_size": PAGE_SIZE,
        "item_counts": dict(counts),
        "item_total": len(states),
        "plan_known": index.has_plan,
        "current_item": index.current,
        "preparation_count": len(index.preparation),
        "preparation_failed": prep_failed,
        "can_retry": not index.active and bool(index.unfinished or index.restart_preparation),
    }
