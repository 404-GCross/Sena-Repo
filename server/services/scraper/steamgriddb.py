"""SteamGridDB scraper — requires API key."""

from __future__ import annotations

import logging

import httpx

from .base import BaseScraper, ScraperResult

logger = logging.getLogger(__name__)


class SteamGridDBScraper(BaseScraper):
    """Scrape SteamGridDB for game covers (needs API key)."""

    source_name = "steamgriddb"

    def __init__(self, api_key: str = "", client: httpx.AsyncClient | None = None):
        super().__init__(client)
        self.api_key = api_key

    async def search(
        self,
        name: str,
        company_hint: str | None = None,
    ) -> list[ScraperResult]:
        if not self.api_key:
            logger.debug("SteamGridDB skipped: no API key configured")
            return []

        client = await self._get_client()
        results = []

        try:
            resp = await client.get(
                "https://www.steamgriddb.com/api/v2/search/autocomplete",
                params={"term": name},
                headers={"Authorization": f"Bearer {self.api_key}"},
                timeout=15.0,
            )
            resp.raise_for_status()
            data = resp.json()

            for item in data.get("data", [])[:5]:
                title = item.get("name", "")
                cover_url = item.get("icon", "") or item.get("logo", "")
                if title:
                    results.append(ScraperResult(
                        title=title,
                        cover_url=cover_url,
                        source_id=str(item.get("id", "")),
                        source_name=self.source_name,
                    ))

        except httpx.HTTPError as e:
            logger.warning(f"SteamGridDB search failed for '{name}': {e}")
        except Exception as e:
            logger.error(f"Unexpected error in SteamGridDB: {e}")

        return results
