from __future__ import annotations

import asyncio
import base64
import dataclasses

import httpx
from pydantic import BaseModel, Field

from services.agent.providers import tool_spec
from services.agent.runtime import object_schema
from services.scraper.orchestrator import _build_scrapers


class Selection(BaseModel):
    candidate: int = Field(ge=0)
    cover: int | None = Field(default=None, ge=0)
    title: str = Field(default="", max_length=512)
    translated_description: str = Field(default="", max_length=2000)
    evidence: str = Field(min_length=1, max_length=2000)
    platforms: dict[str, str] = Field(default_factory=dict)


class Catalog:
    def __init__(self, config, actor_id, runtime):
        self.scrapers = _build_scrapers(config, hikarinagi_user_id=actor_id)
        self.runtime = runtime
        self.results = []
        self.queries = {}
        self.inspected = set()
        self.config = config

    async def close(self):
        for scraper in self.scrapers:
            await scraper.close()

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
                rows = await asyncio.wait_for(scraper.search(query), timeout=35)
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
        images, indexes = [], []
        async with httpx.AsyncClient(
            timeout=15, proxy=self.config.proxy or None, trust_env=False
        ) as client:
            for i in args.get("covers", [])[:4]:
                if type(i) is not int or not 0 <= i < len(urls):
                    continue
                try:
                    async with client.stream("GET", urls[i]) as response:
                        response.raise_for_status()
                        mime = response.headers.get("content-type", "").split(";")[0]
                        if mime not in {"image/jpeg", "image/png", "image/webp"}:
                            continue
                        data = bytearray()
                        async for chunk in response.aiter_bytes():
                            data.extend(chunk)
                            if len(data) > 2 * 1024 * 1024:
                                raise ValueError()
                        images.append(
                            f"data:{mime};base64," + base64.b64encode(data).decode()
                        )
                        indexes.append(i)
                        self.inspected.add((index, i))
                except (httpx.HTTPError, ValueError):
                    continue
        return {"candidate": index, "covers": indexes, "_images": images}

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
    return catalog.selected(data)
