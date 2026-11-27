from __future__ import annotations

import asyncio
import dataclasses
import re

from pydantic import BaseModel, Field

from services.agent.covers import CoverChecker, CoverDecision
from services.agent.providers import tool_spec
from services.agent.runtime import AgentBudget, object_schema
from services.scraper.base import title_search_key
from services.scraper.orchestrator import _build_scrapers
from services.task_stop import stoppable_request


class Selection(BaseModel):
    candidate: int = Field(ge=0)
    cover: int | None = Field(default=None, ge=0)
    title: str = Field(default="", max_length=512)
    translated_description: str = Field(default="", max_length=2000)
    evidence: str = Field(min_length=1, max_length=2000)
    platforms: dict[str, str] = Field(default_factory=dict)


def _work_id(source, value):
    value = str(value or "").strip().lower()
    return value.removeprefix("v") if source in {"vndb", "vndb_kana"} else value


def _anchor_matches(result, saved_ids):
    matches = []
    for source, candidate in {**result.external_ids, result.source_name: result.source_id}.items():
        key = "vndb" if source == "vndb_kana" else source
        saved = saved_ids.get(f"{key}_id")
        if saved and candidate:
            matches.append(_work_id(source, candidate) == _work_id(source, saved))
    return matches


class Catalog:
    def __init__(self, config, actor_id, runtime):
        self.scrapers = _build_scrapers(config, hikarinagi_user_id=actor_id)
        self.runtime = runtime
        self.results = []
        self.queries = {}
        self.inspected = set()
        self.config = config
        self.cover_checker = CoverChecker(config, runtime)
        self.cover_data = None
        self.cover_review = ""
        self.cover_checks = []
        self.cover_decision = None

    async def close(self):
        try:
            for scraper in self.scrapers:
                await scraper.close()
        finally:
            await self.cover_checker.close()

    def describe(self, index, result):
        return {
            "candidate": index,
            "source": result.source_name,
            "id": result.source_id,
            "title": result.title,
            "aliases": result.aliases[:10],
            "developer": result.developer,
            "description": result.description[:1200],
            "external_ids": result.external_ids,
            "covers": [
                {
                    "index": i,
                    "metadata": (getattr(result, "cover_metadata", {}) or {}).get(
                        url, {}
                    ),
                }
                for i, url in enumerate(self.covers(result))
            ],
        }

    @staticmethod
    def covers(result):
        urls = list(
            dict.fromkeys([u for u in [result.cover_url, *result.cover_urls] if u])
        )[:12]
        # A source's portrait-first picker can fill all twelve slots before its first wide cover.
        if len(urls) == 12:
            for url, info in result.cover_metadata.items():
                if url not in urls and info.get("width", 0) > info.get("height", 0) > 0:
                    urls.append(url)
                    if len(urls) == 16:
                        break
        return urls

    def cover_target(self, result, urls, context):
        def names(work):
            return list(
                dict.fromkeys(
                    t[:512]
                    for t in [work.title, *work.cover_titles, *work.aliases]
                    if t
                )
            )[:64]

        others = [
            row
            for row in self.results
            if row.source_name == result.source_name
            and row.source_id != result.source_id
        ]
        other_titles = {title_search_key(t) for row in others for t in names(row)}
        other_urls = {url for row in others for url in self.covers(row)}
        titles = names(result)
        return {
            "game": context.get("game") or result.title,
            "titles": titles,
            "source": result.source_name,
            "source_id": result.source_id,
            "developer": result.developer,
            "release_date": result.release_date,
            "external_ids": result.external_ids,
            "saved_ids": context.get("saved_ids", {}),
            "ambiguous_titles": [
                t for t in titles if title_search_key(t) in other_titles
            ],
            "cross_listed_covers": [
                i for i, url in enumerate(urls) if url in other_urls
            ],
        }

    async def bound_cover_sources(self, original, saved_ids):
        primary_ids = {f"{key}_id": value for key, value in original.external_ids.items()}
        primary_key = "vndb" if original.source_name == "vndb_kana" else original.source_name
        primary_ids[f"{primary_key}_id"] = original.source_id
        for scraper in self.scrapers:
            source = scraper.source_name
            if source == original.source_name:
                continue
            key = "vndb" if source == "vndb_kana" else source
            saved = _work_id(source, saved_ids.get(f"{key}_id"))
            if not re.fullmatch(r"[1-9][0-9]*", saved):
                continue
            try:
                await self.runtime.check(model=True)
            except AgentBudget:
                self.cover_checks.append({"source": source, "source_id": saved, "reason": "模型预算或配置已变化，停止补查"})
                return
            try:
                query = f"v{saved}" if key == "vndb" else saved
                rows = await asyncio.wait_for(stoppable_request(scraper.search(query)), timeout=35)
            except Exception as exc:
                self.cover_checks.append({"source": source, "source_id": saved,
                                          "reason": f"按作品 ID 读取来源失败：{type(exc).__name__}"})
                continue
            for row in rows:
                if (row.source_name == source and _work_id(source, row.source_id) == saved
                        and all(_anchor_matches(row, saved_ids)) and all(_anchor_matches(row, primary_ids))):
                    yield row
                    break
            else:
                self.cover_checks.append({"source": source, "source_id": saved, "reason": "来源没有返回该作品 ID 的匹配记录"})

    async def choose_cover(self, original, context):
        saved_ids = context.get("saved_ids", {})
        matches = _anchor_matches(original, saved_ids)
        if not all(matches):
            return CoverDecision(reason="候选作品与已保存的作品 ID 冲突，保留现有封面待复核")

        primary = self.cover_target(original, self.covers(original), context)
        assessments = {}

        async def inspect(work, preferred=None):
            urls = self.covers(work)
            target = self.cover_target(work, urls, context)
            target["game"] = primary["game"]
            metadata = work.cover_metadata
            if work is not original:
                target["primary_work"] = primary
                primary_keys = {title_search_key(title) for title in primary["titles"]}
                ambiguous = list(dict.fromkeys(primary["ambiguous_titles"] + target["ambiguous_titles"]))
                shared = primary_keys.intersection(title_search_key(t) for t in target["titles"])
                shared.difference_update(title_search_key(t) for t in ambiguous)
                # A broader catalog ID locates artwork, but cannot certify a different edition.
                if shared - {""}:
                    target["titles"] = list(dict.fromkeys(primary["titles"] + target["titles"]))
                else:
                    target["titles"] = primary["titles"]
                    metadata = {url: {"language": value.get("language")} for url, value in metadata.items()}
                target["ambiguous_titles"] = ambiguous
            decision = await self.cover_checker.choose(urls, metadata, preferred, target=target, assessments=assessments)
            decision.source, decision.source_id = work.source_name, work.source_id
            for check in decision.checks or [{"reason": decision.reason}]:
                self.cover_checks.append({**check, "source": work.source_name, "source_id": work.source_id})
            return decision

        best = await inspect(original, self.selection.cover)
        if self.runtime.settings.vision and matches and best.priority > 0:
            async for work in self.bound_cover_sources(original, saved_ids):
                candidate = await inspect(work)
                if candidate.priority < best.priority:
                    best = candidate
                elif best.asset is None and candidate.checks:
                    best.reason = candidate.reason
                if best.priority == 0:
                    break
        return best

    async def search(self, args):
        query = str(args.get("query", ""))[:256].strip()
        source = args.get("source")
        if not query:
            return {"error": "Query is required"}
        key = (query, source)
        if key in self.queries:
            return self.queries[key]
        found = []
        for scraper in self.scrapers:
            if source and scraper.source_name != source:
                continue
            await self.runtime.check()
            try:
                rows = await asyncio.wait_for(stoppable_request(scraper.search(query)), timeout=35)
            except Exception:
                continue
            for result in rows[:5]:
                result.source_name = scraper.source_name
                if not result.source_id:
                    continue
                index = len(self.results)
                self.results.append(result)
                found.append(self.describe(index, result))
        answer = {
            "candidates": found,
            "source_order": [s.source_name for s in self.scrapers],
        }
        self.queries[key] = answer
        return answer

    async def inspect_covers(self, args):
        if not self.runtime.settings.vision:
            return {
                "error": "Image input disabled; use verified cover metadata or preserve existing cover"
            }
        index = args.get("candidate")
        if type(index) is not int or not 0 <= index < len(self.results):
            return {"error": "Unknown candidate"}
        urls = self.covers(self.results[index])
        images, indexes, dimensions = [], [], []
        for i in args.get("covers", [])[:4]:
            if type(i) is not int or not 0 <= i < len(urls):
                continue
            await self.runtime.check()
            asset = await self.cover_checker.load(urls[i])
            if asset is None:
                continue
            images.append(asset.preview.uri)
            indexes.append(i)
            dimensions.append(
                {
                    "cover": i,
                    "width": asset.preview.width,
                    "height": asset.preview.height,
                }
            )
            self.inspected.add((index, i))
        return {
            "candidate": index,
            "covers": indexes,
            "dimensions": dimensions,
            "_images": images,
        }

    def tools(self):
        return {
            "search": (
                tool_spec(
                    "search",
                    "Search enabled sources in configured order; returns real candidates",
                    object_schema(
                        {"query": {"type": "string"}, "source": {"type": "string"}},
                        ["query"],
                    ),
                ),
                self.search,
            ),
            "inspect_covers": (
                tool_spec(
                    "inspect_covers",
                    "Inspect actual cover images for a verified candidate",
                    object_schema(
                        {
                            "candidate": {"type": "integer"},
                            "covers": {
                                "type": "array",
                                "items": {"type": "integer"},
                                "maxItems": 4,
                            },
                        }
                    ),
                ),
                self.inspect_covers,
            ),
        }

    def selected(self, data):
        selection = Selection.model_validate(data)
        self.selection = selection
        if selection.candidate >= len(self.results):
            raise ValueError("未验证的候选")
        result = dataclasses.replace(self.results[selection.candidate])
        if selection.title and selection.title in [result.title, *result.aliases]:
            result.title = selection.title
        if (
            selection.translated_description
            and self.runtime.settings.translate_description
        ):
            result.description = selection.translated_description
        urls = self.covers(result)
        if selection.cover is not None:
            if selection.cover >= len(urls):
                raise ValueError("未验证的封面")
            result.cover_url = urls[selection.cover]
            if self.runtime.settings.cover_language == "zh":
                metadata = result.cover_metadata.get(result.cover_url, {})
                language = str(metadata.get("language") or "").lower()
                if (
                    language
                    not in {
                        "zh",
                        "zh-cn",
                        "zh-tw",
                        "zh-hans",
                        "zh-hant",
                        "chs",
                        "cht",
                        "中文",
                        "简体中文",
                        "繁体中文",
                    }
                    and (selection.candidate, selection.cover) not in self.inspected
                ):
                    if self.runtime.settings.cover_fallback in {"keep", "review"}:
                        result.cover_url = ""
        elif self.runtime.settings.cover_fallback in {"keep", "review"}:
            result.cover_url = ""
        return result, selection.evidence


async def select_metadata(runtime, catalog, context):
    preferences = runtime.settings.model_dump(
        include={
            "cover_language",
            "cover_fallback",
            "portrait",
            "high_resolution",
            "name_language",
            "translate_description",
            "preferences",
        }
    )
    data = await runtime.reason(
        "metadata",
        {
            **context,
            "preferences": preferences,
            "sources": [s.source_name for s in catalog.scrapers],
        },
        Selection.model_json_schema(),
        catalog.tools(),
    )
    result, evidence = catalog.selected(data)
    if not context.get("replace_cover", True):
        result.cover_url = ""
    elif runtime.settings.portrait:
        original = catalog.results[catalog.selection.candidate]
        decision = await catalog.choose_cover(original, context)
        catalog.cover_decision = decision
        catalog.cover_review = decision.reason
        result.cover_url = decision.asset.url if decision.asset else ""
        catalog.cover_data = decision.asset.data if decision.asset else None
    return result, evidence
