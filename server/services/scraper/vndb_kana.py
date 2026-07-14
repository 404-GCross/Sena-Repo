"""VNDB Kana scraper — improved with LunaBox alignment."""

from __future__ import annotations

import logging
import re

import httpx

from .base import BaseScraper, ScraperResult

logger = logging.getLogger(__name__)

VNDB_FIELDS = (
    "id,title,titles.lang,titles.title,titles.latin,titles.official,titles.main,"
    "image.url,screenshots.url,description,rating,released,"
    "length,length_minutes,"
    "developers.name,tags.name,tags.rating,tags.spoiler"
)


def _normalize_vndb_id(value: str) -> str | None:
    query = value.strip().lower()
    if re.fullmatch(r"v?\d+", query):
        return query if query.startswith("v") else f"v{query}"
    return None


def _build_vndb_body(query: str, *, fields: str, results: int = 5) -> dict:
    vndb_id = _normalize_vndb_id(query)
    if vndb_id:
        return {
            "filters": ["id", "=", vndb_id],
            "fields": fields,
            "results": 1,
        }
    return {
        "filters": ["search", "=", query],
        "fields": fields,
        "sort": "searchrank",
        "results": results,
    }


class VndbKanaScraper(BaseScraper):
    """VNDB Kana API scraper with Chinese title preference and tag extraction."""

    source_name = "vndb_kana"
    base_url = "https://api.vndb.org/kana/vn"

    async def search(
        self,
        name: str,
        company_hint: str | None = None,
    ) -> list[ScraperResult]:
        client = await self._get_client()
        results = []
        try:
            body = _build_vndb_body(name, fields=VNDB_FIELDS)
            resp = await self._request_with_retry(
                client, "POST", self.base_url,
                json=body,
                headers={"Content-Type": "application/json"},
            )
            items = resp.json().get("results", [])
            for item in items:
                results.append(self._parse(item))
        except Exception as e:
            logger.warning(f"VNDB Kana failed for '{name}': {e}")
        return results

    def _parse(self, item: dict) -> ScraperResult:
        # Pick best display title (Chinese preferred, like LunaBox)
        titles = item.get("titles", [])
        title = self._pick_title(titles) or item.get("title", "")

        # Developer
        devs = item.get("developers", [])
        developer = devs[0].get("name", "") if devs else ""

        # Cover
        image = item.get("image") or {}
        cover = image.get("url", "")

        # Hero: first landscape screenshot, all screenshots for picker
        screenshots = item.get("screenshots") or []
        hero = screenshots[0].get("url", "") if screenshots else ""
        all_shots = [s.get("url", "") for s in screenshots if s.get("url")]

        # Tags (filter rating >= 1.5, sort by rating desc, top 5)
        tags = item.get("tags", [])
        filtered = [t for t in tags if t.get("rating", 0) >= 1.5]
        filtered.sort(key=lambda t: t.get("rating", 0), reverse=True)

        return ScraperResult(
            title=title,
            developer=developer,
            description=(item.get("description") or ""),
            release_date=(item.get("released") or ""),
            cover_url=cover,
            hero_url=hero,
            screenshot_urls=all_shots,
            source_id=str(item.get("id", "")),
            source_name=self.source_name,
            length=(item.get("length") or 0),
            length_minutes=(item.get("length_minutes") or 0),
        )

    def _pick_title(self, titles: list[dict]) -> str:
        """Pick best display title: Chinese > main > official > first."""
        for lang in ("zh-Hans", "zh-Hant", "zh"):
            for t in titles:
                if t.get("lang") == lang:
                    return t.get("title") or t.get("latin") or ""

        # Prefer main + official
        best, best_score = "", -1
        for t in titles:
            name = t.get("title") or t.get("latin") or ""
            if not name:
                continue
            score = 0
            if t.get("main"):
                score += 2
            if t.get("official"):
                score += 1
            if score > best_score:
                best_score = score
                best = name
        return best


class VndbTitlesScraper(BaseScraper):
    """Legacy VNDB scraper — uses simpler Kana call without titles array."""

    source_name = "vndb"
    base_url = "https://api.vndb.org/kana/vn"

    async def search(
        self,
        name: str,
        company_hint: str | None = None,
    ) -> list[ScraperResult]:
        client = await self._get_client()
        results = []
        try:
            fields = "id,title,image.url,screenshots.url,description,rating,released,developers.name"
            body = _build_vndb_body(name, fields=fields)
            resp = await self._request_with_retry(
                client, "POST", self.base_url,
                json=body,
                headers={"Content-Type": "application/json"},
            )
            for item in resp.json().get("results", []):
                devs = item.get("developers", [])
                image = item.get("image") or {}
                screenshots = item.get("screenshots") or []
                hero = screenshots[0].get("url", "") if screenshots else ""
                all_shots = [s.get("url", "") for s in screenshots if s.get("url")]
                results.append(ScraperResult(
                    title=item.get("title", ""),
                    developer=devs[0].get("name", "") if devs else "",
                    description=item.get("description", ""),
                    release_date=item.get("released", ""),
                    cover_url=image.get("url", ""),
                    hero_url=hero,
                    screenshot_urls=all_shots,
                    source_id=str(item.get("id", "")),
                    source_name=self.source_name,
                ))
        except Exception as e:
            logger.warning(f"VNDB failed for '{name}': {e}")
        return results
