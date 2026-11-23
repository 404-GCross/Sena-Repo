from __future__ import annotations

import asyncio
import dataclasses

from pydantic import BaseModel, Field

from services.agent.covers import CoverChecker, CoverDecision
from services.agent.providers import tool_spec
from services.agent.runtime import object_schema
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


def _conflicting_work_ids(result, saved_ids):
    anchors = {**result.external_ids, result.source_name: result.source_id}
    for source, candidate in anchors.items():
        key = "vndb" if source == "vndb_kana" else source
        saved = str(saved_ids.get(f"{key}_id") or "").strip().lower()
        candidate = str(candidate or "").strip().lower()
        if key == "vndb":
            saved, candidate = saved.removeprefix("v"), candidate.removeprefix("v")
        if saved and candidate and saved != candidate:
            return True
    return False


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
        return list(
            dict.fromkeys([u for u in [result.cover_url, *result.cover_urls] if u])
        )[:12]

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
        urls = catalog.covers(original)
        if _conflicting_work_ids(original, context.get("saved_ids", {})):
            decision = CoverDecision(
                reason="候选作品与已保存的作品 ID 冲突，保留现有封面待复核"
            )
        else:
            decision = await catalog.cover_checker.choose(
                urls,
                original.cover_metadata,
                catalog.selection.cover,
                target=catalog.cover_target(original, urls, context),
            )
        catalog.cover_decision = decision
        catalog.cover_checks = decision.checks
        catalog.cover_review = decision.reason
        result.cover_url = decision.asset.url if decision.asset else ""
        catalog.cover_data = decision.asset.data if decision.asset else None
    return result, evidence
