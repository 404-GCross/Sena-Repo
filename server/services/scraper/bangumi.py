"""Bangumi scraper — uses public API (no auth required)."""

from __future__ import annotations

import logging
from urllib.parse import quote

import httpx

from .base import BaseScraper, ScraperResult

logger = logging.getLogger(__name__)


class BangumiScraper(BaseScraper):
    """Scrape Bangumi for game metadata using the public API."""

    source_name = "bangumi"
    base_url = "https://api.bgm.tv"

    async def search(
        self,
        name: str,
        company_hint: str | None = None,
    ) -> list[ScraperResult]:
        client = await self._get_client()
        results = []

        try:
            # Step 1: Search for subject
            resp = await client.get(
                f"{self.base_url}/search/subject/{quote(name)}",
                params={
                    "type": 4,  # 4 = game
                    "responseGroup": "large",
                    "max_results": 5,
                },
                timeout=15.0,
            )
            resp.raise_for_status()
            data = resp.json()

            for item in data.get("list", []):
                # Bangumi image URL needs to be transformed
                cover_url = item.get("images", {}).get("large", "")

                results.append(ScraperResult(
                    title=item.get("name_cn", "") or item.get("name", ""),
                    developer="",  # Bangumi search doesn't return developer easily
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
