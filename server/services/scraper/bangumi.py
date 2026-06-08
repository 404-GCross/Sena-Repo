"""Bangumi scraper — v0 POST API with mirror fallback."""

from __future__ import annotations

import logging

import httpx

from .base import BaseScraper, ScraperResult, clean_title

logger = logging.getLogger(__name__)

BGM_MAIN = "https://api.bgm.tv"
BGM_MIRROR = "https://api.bangumi.one"


class BangumiScraper(BaseScraper):
    """Scrape Bangumi via v0 POST API with optional token + mirror fallback."""

    source_name = "bangumi"

    def __init__(
        self,
        proxy: str = "",
        token: str = "",
        client: httpx.AsyncClient | None = None,
    ):
        super().__init__(proxy=proxy, client=client)
        self.token = token

    async def search(
        self,
        name: str,
        company_hint: str | None = None,
    ) -> list[ScraperResult]:
        keyword = clean_title(name)
        if not keyword:
            return []

        # Try main endpoint first, then mirror
        for endpoint, use_proxy in [(BGM_MAIN, True), (BGM_MIRROR, False)]:
            try:
                results = await self._do_search(endpoint, keyword, use_proxy)
                if results:
                    return results
            except Exception as e:
                logger.debug(f"Bangumi {endpoint} failed: {e}")
        return []

    async def _do_search(
        self, endpoint: str, keyword: str, use_proxy: bool
    ) -> list[ScraperResult]:
        kwargs = {"timeout": httpx.Timeout(15.0)}
        if use_proxy and self.proxy:
            kwargs["proxy"] = self.proxy
        async with httpx.AsyncClient(**kwargs) as client:
            body = {
                "keyword": keyword,
                "sort": "match",
                "filter": {"type": [4]},  # 4 = game
            }
            headers = {
                "Content-Type": "application/json; charset=UTF-8",
                "Accept": "application/json",
                "User-Agent": "SenaRepo/0.1 (https://github.com/404-GCross/Sena-Repo)",
            }
            if self.token:
                headers["Authorization"] = f"Bearer {self.token}"

            url = f"{endpoint}/v0/search/subjects?limit=3&offset=0"
            resp = await self._request_with_retry(client, "POST", url, json=body, headers=headers)
            data = resp.json()
            return [self._parse(item) for item in data.get("data", []) if item.get("id")]

    def _parse(self, item: dict) -> ScraperResult:
        images = item.get("images", {})
        cover = images.get("large", "") or images.get("common", "") or images.get("grid", "")
        if cover.startswith("//"):
            cover = "https:" + cover

        tags = item.get("tags", [])
        tag_names = [t.get("name", "") for t in tags[:5] if t.get("name")]

        return ScraperResult(
            title=item.get("name_cn", "") or item.get("name", ""),
            description=item.get("summary", ""),
            release_date=item.get("date", ""),
            cover_url=cover,
            source_id=str(item.get("id", "")),
            source_name=self.source_name,
        )
