"""muyueGalgame scraper — web scraping based."""

from __future__ import annotations

import logging
from urllib.parse import quote

import httpx
from bs4 import BeautifulSoup

from .base import BaseScraper, ScraperResult

logger = logging.getLogger(__name__)


class MuyueScraper(BaseScraper):
    """Scrape muyueGalgame for game metadata."""

    source_name = "muyue"
    base_url = "https://www.muyuegalgame.com"

    async def search(
        self,
        name: str,
        company_hint: str | None = None,
    ) -> list[ScraperResult]:
        client = await self._get_client()
        results = []

        try:
            resp = await client.get(
                f"{self.base_url}/search",
                params={"q": name},
                timeout=15.0,
                headers={
                    "User-Agent": "Mozilla/5.0 (compatible; SenaRepo/0.1)",
                },
            )
            resp.raise_for_status()
            soup = BeautifulSoup(resp.text, "lxml")

            for item in soup.select(".search-result-item")[:5]:
                title_el = item.select_one(".title")
                cover_el = item.select_one("img")
                desc_el = item.select_one(".description")

                title = title_el.text.strip() if title_el else ""
                cover_url = cover_el.get("src", "") if cover_el else ""
                description = desc_el.text.strip() if desc_el else ""

                if title:
                    results.append(ScraperResult(
                        title=title,
                        description=description,
                        cover_url=cover_url,
                        source_name=self.source_name,
                    ))

        except httpx.HTTPError as e:
            logger.warning(f"muyue search failed for '{name}': {e}")
        except Exception as e:
            logger.error(f"Unexpected error in muyue: {e}")

        return results
