"""IGDB scraper — requires Twitch Client ID and Secret."""

from __future__ import annotations

import logging

import httpx

from .base import BaseScraper, ScraperResult

logger = logging.getLogger(__name__)


class IGDBScraper(BaseScraper):
    """Scrape IGDB for game covers (needs Client ID + Secret)."""

    source_name = "igdb"

    def __init__(
        self,
        client_id: str = "",
        client_secret: str = "",
        client: httpx.AsyncClient | None = None,
    ):
        super().__init__(client)
        self.client_id = client_id
        self.client_secret = client_secret
        self._access_token: str | None = None

    async def _authenticate(self) -> bool:
        if not self.client_id or not self.client_secret:
            return False
        if self._access_token:
            return True

        client = await self._get_client()
        try:
            resp = await client.post(
                "https://id.twitch.tv/oauth2/token",
                params={
                    "client_id": self.client_id,
                    "client_secret": self.client_secret,
                    "grant_type": "client_credentials",
                },
                timeout=10.0,
            )
            resp.raise_for_status()
            self._access_token = resp.json().get("access_token", "")
            return bool(self._access_token)
        except Exception as e:
            logger.warning(f"IGDB auth failed: {e}")
            return False

    async def search(
        self,
        name: str,
        company_hint: str | None = None,
    ) -> list[ScraperResult]:
        if not await self._authenticate():
            logger.debug("IGDB skipped: no credentials or auth failed")
            return []

        client = await self._get_client()
        results = []

        try:
            resp = await client.post(
                "https://api.igdb.com/v4/games",
                data=f'search "{name}"; fields name,cover.url; limit 5;',
                headers={
                    "Client-ID": self.client_id,
                    "Authorization": f"Bearer {self._access_token}",
                },
                timeout=15.0,
            )
            resp.raise_for_status()

            for item in resp.json():
                cover_url = ""
                if item.get("cover") and item["cover"].get("url"):
                    cover_url = "https:" + item["cover"]["url"].replace("t_thumb", "t_cover_big_2x")

                results.append(ScraperResult(
                    title=item.get("name", ""),
                    cover_url=cover_url,
                    source_id=str(item.get("id", "")),
                    source_name=self.source_name,
                ))

        except httpx.HTTPError as e:
            logger.warning(f"IGDB search failed for '{name}': {e}")
        except Exception as e:
            logger.error(f"Unexpected error in IGDB: {e}")

        return results
