"""VNDB Kana v2 scraper — no authentication required.

Uses the Kana API which is a simplified search endpoint.
Ref: https://kana.vndb.org/
"""

from __future__ import annotations

import logging
from urllib.parse import quote

import httpx

from .base import BaseScraper, ScraperResult

logger = logging.getLogger(__name__)


class VndbKanaScraper(BaseScraper):
    """Scrape VNDB using the Kana v2 API (no auth)."""

    source_name = "vndb_kana"
    base_url = "https://kana.vndb.org"

    async def search(
        self,
        name: str,
        company_hint: str | None = None,
    ) -> list[ScraperResult]:
        """Search VNDB Kana API for visual novel metadata."""
        client = await self._get_client()
        results = []

        try:
            # Kana API: POST with JSON body
            payload = {
                "filters": [
                    {"type": "search", "search": name},
                ],
                "sort": "searchrank",
                "page": 1,
                "limit": 5,
            }

            resp = await client.post(
                f"{self.base_url}/api/v2/search",
                json=payload,
                headers={"Content-Type": "application/json"},
                timeout=15.0,
            )
            resp.raise_for_status()
            data = resp.json()

            for item in data.get("results", []):
                result = ScraperResult(
                    title=item.get("title", ""),
                    developer=item.get("developer", ""),
                    description=item.get("description", ""),
                    release_date=item.get("released", ""),
                    cover_url=item.get("image", {}).get("url", ""),
                    source_id=item.get("id", ""),
                    source_name=self.source_name,
                )
                results.append(result)

        except httpx.HTTPError as e:
            logger.warning(f"VNDB Kana search failed for '{name}': {e}")
        except Exception as e:
            logger.error(f"Unexpected error in VNDB Kana: {e}")

        return results


class VndbTitlesScraper(BaseScraper):
    """Search VNDB using the public titles JSON API.
    This is a lighter endpoint that often works without auth.
    """

    source_name = "vndb"
    base_url = "https://api.vndb.org/kana"

    async def search(
        self,
        name: str,
        company_hint: str | None = None,
    ) -> list[ScraperResult]:
        client = await self._get_client()
        results = []

        try:
            resp = await client.get(
                f"{self.base_url}/vn",
                params={
                    "q": name,
                    "f": "title,released,developers.name,image.url",
                },
                timeout=15.0,
            )
            resp.raise_for_status()
            data = resp.json()

            for item in data.get("results", []):
                cover_url = ""
                if item.get("image") and item["image"].get("url"):
                    cover_url = item["image"]["url"]

                dev_name = ""
                devs = item.get("developers", [])
                if devs:
                    dev_name = devs[0].get("name", "")

                results.append(ScraperResult(
                    title=item.get("title", ""),
                    developer=dev_name,
                    release_date=item.get("released", ""),
                    cover_url=cover_url,
                    source_id=item.get("id", ""),
                    source_name=self.source_name,
                ))

        except httpx.HTTPError as e:
            logger.warning(f"VNDB search failed for '{name}': {e}")
        except Exception as e:
            logger.error(f"Unexpected error in VNDB: {e}")

        return results
