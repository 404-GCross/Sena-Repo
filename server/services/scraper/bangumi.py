"""Bangumi scraper — supports public API and authenticated v0 API."""

from __future__ import annotations

import logging
from urllib.parse import quote

import httpx

from .base import BaseScraper, ScraperResult

logger = logging.getLogger(__name__)


class BangumiScraper(BaseScraper):
    """Scrape Bangumi for game metadata.

    Public old API works without auth (rate-limited).
    v0 API requires a token from https://bgm.tv/dev/app (higher limits).
    """

    source_name = "bangumi"
    base_url = "https://api.bgm.tv"

    def __init__(
        self,
        token: str = "",
        client: httpx.AsyncClient | None = None,
    ):
        super().__init__(client)
        self.token = token

    async def search(
        self,
        name: str,
        company_hint: str | None = None,
    ) -> list[ScraperResult]:
        if self.token:
            return await self._search_v0(name)
        return await self._search_public(name)

    async def _search_v0(self, name: str) -> list[ScraperResult]:
        """Search via authenticated v0 API (requires token)."""
        client = await self._get_client()
        results = []

        try:
            resp = await client.get(
                f"{self.base_url}/v0/search/subjects",
                params={
                    "keyword": name,
                    "type": 4,   # 4 = game
                    "limit": 5,
                    "responseGroup": "large",
                },
                headers={
                    "Authorization": f"Bearer {self.token}",
                    "User-Agent": "SenaRepo/0.1 (https://github.com/404-GCross/Sena-Repo)",
                },
                timeout=15.0,
            )
            resp.raise_for_status()
            data = resp.json()

            for item in data.get("data", []):
                cover_url = ""
                if item.get("images"):
                    cover_url = item["images"].get("large", "")

                results.append(ScraperResult(
                    title=item.get("name_cn", "") or item.get("name", ""),
                    description=item.get("summary", ""),
                    release_date=item.get("date", ""),
                    cover_url=cover_url,
                    source_id=str(item.get("id", "")),
                    source_name=self.source_name,
                ))

        except httpx.HTTPError as e:
            logger.warning(f"Bangumi v0 search failed for '{name}': {e}")
        except Exception as e:
            logger.error(f"Unexpected error in Bangumi v0: {e}")

        return results

    async def _search_public(self, name: str) -> list[ScraperResult]:
        """Search via old public API (no auth, rate-limited)."""
        client = await self._get_client()
        results = []

        try:
            resp = await client.get(
                f"{self.base_url}/search/subject/{quote(name)}",
                params={
                    "type": 4,
                    "responseGroup": "large",
                    "max_results": 5,
                },
                timeout=15.0,
            )
            resp.raise_for_status()
            data = resp.json()

            for item in data.get("list", []):
                cover_url = item.get("images", {}).get("large", "")

                results.append(ScraperResult(
                    title=item.get("name_cn", "") or item.get("name", ""),
                    description=item.get("summary", ""),
                    release_date=item.get("air_date", ""),
                    cover_url=cover_url,
                    source_id=str(item.get("id", "")),
                    source_name=self.source_name,
                ))

        except httpx.HTTPError as e:
            logger.warning(f"Bangumi search failed for '{name}': {e}")
        except Exception as e:
            logger.error(f"Unexpected error in Bangumi: {e}")

        return results
