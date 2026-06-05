"""Steam scraper — uses public Store API (no key needed for search)."""

from __future__ import annotations

import logging

import httpx

from .base import BaseScraper, ScraperResult

logger = logging.getLogger(__name__)


class SteamScraper(BaseScraper):
    """Scrape Steam store for game metadata using public API."""

    source_name = "steam"
    base_url = "https://store.steampowered.com/api"

    async def search(
        self,
        name: str,
        company_hint: str | None = None,
    ) -> list[ScraperResult]:
        client = await self._get_client()
        results = []

        try:
            # Steam store search API (public, no key needed)
            resp = await client.get(
                f"{self.base_url}/storesearch",
                params={"term": name, "l": "english", "cc": "US"},
                timeout=15.0,
            )
            resp.raise_for_status()
            data = resp.json()

            for item in data.get("items", [])[:5]:
                app_id = item.get("id", "")
                cover_url = item.get("tiny_image", "")
                # Convert tiny to full size
                if cover_url:
                    cover_url = cover_url.replace("/capsule_sm_120.jpg", "/library_600x900.jpg")

                results.append(ScraperResult(
                    title=item.get("name", ""),
                    cover_url=cover_url,
                    source_id=str(app_id),
                    source_name=self.source_name,
                ))

        except httpx.HTTPError as e:
            logger.warning(f"Steam search failed for '{name}': {e}")
        except Exception as e:
            logger.error(f"Unexpected error in Steam: {e}")

        return results
