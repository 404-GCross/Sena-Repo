"""DLsite scraper — web scraping (works best with JP proxy)."""

from __future__ import annotations

import logging

import httpx
from bs4 import BeautifulSoup

from .base import BaseScraper, ScraperResult

logger = logging.getLogger(__name__)


class DLsiteScraper(BaseScraper):
    """Scrape DLsite for game metadata."""

    source_name = "dlsite"

    async def search(
        self,
        name: str,
        company_hint: str | None = None,
    ) -> list[ScraperResult]:
        client = await self._get_client()
        results = []

        try:
            resp = await client.get(
                "https://www.dlsite.com/maniax/fsr/=/keyword/work_name",
                params={"keyword": name, "per_page": 5},
                timeout=15.0,
                headers={
                    "User-Agent": "Mozilla/5.0 (compatible; SenaRepo/0.1)",
                    "Accept-Language": "ja,zh;q=0.9,en;q=0.8",
                },
            )
            resp.raise_for_status()
            soup = BeautifulSoup(resp.text, "lxml")

            for item in soup.select(".search_result_item")[:5]:
                title_el = item.select_one(".work_name a")
                cover_el = item.select_one(".work_thumb img")
                maker_el = item.select_one(".maker_name a")

                title = title_el.text.strip() if title_el else ""
                cover_url = cover_el.get("src", "") if cover_el else ""
                developer = maker_el.text.strip() if maker_el else ""

                if title:
                    results.append(ScraperResult(
                        title=title,
                        developer=developer,
                        cover_url="https:" + cover_url if cover_url.startswith("//") else cover_url,
                        source_name=self.source_name,
                    ))

        except httpx.HTTPError as e:
            logger.warning(f"DLsite search failed for '{name}': {e}")
        except Exception as e:
            logger.error(f"Unexpected error in DLsite: {e}")

        return results
