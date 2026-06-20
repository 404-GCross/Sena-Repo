"""IGDB scraper — requires Twitch Client ID and Secret."""

from __future__ import annotations

import logging
import time
from datetime import datetime, timezone

import httpx

from .base import BaseScraper, ScraperResult

logger = logging.getLogger(__name__)


class IGDBScraper(BaseScraper):
    """Scrape IGDB for game covers + screenshots + metadata."""

    source_name = "igdb"

    def __init__(
        self,
        proxy: str = "",
        client_id: str = "",
        client_secret: str = "",
        client: httpx.AsyncClient | None = None,
    ):
        super().__init__(proxy=proxy, client=client)
        self.client_id = client_id
        self.client_secret = client_secret
        self._access_token: str = ""
        self._token_expires: float = 0.0

    async def _authenticate(self) -> bool:
        if not self.client_id or not self.client_secret:
            return False
        now = time.monotonic()
        if self._access_token and now < self._token_expires:
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
            data = resp.json()
            self._access_token = data.get("access_token", "")
            expires_in = data.get("expires_in", 86400)
            self._token_expires = now + max(300, expires_in - 300)
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
            resp = await self._request_with_retry(
                client, "POST",
                "https://api.igdb.com/v4/games",
                data=f'search "{name}"; fields name,cover.url,screenshots.url,summary,first_release_date; limit 5;',
                headers={
                    "Client-ID": self.client_id,
                    "Authorization": f"Bearer {self._access_token}",
                },
            )
            data = resp.json()
            for item in data:
                cover_url = ""
                if item.get("cover") and item["cover"].get("url"):
                    cover_url = "https:" + item["cover"]["url"].replace("t_thumb", "t_cover_big_2x")

                # Screenshots for hero/landscape picker
                shots = item.get("screenshots") or []
                shot_urls: list[str] = []
                hero = ""
                for s in shots:
                    if s.get("url"):
                        url = "https:" + s["url"].replace("t_thumb", "t_screenshot_big")
                        shot_urls.append(url)
                        if not hero:
                            hero = url

                # Release date: Unix timestamp → YYYY-MM-DD
                release_date = ""
                ts = item.get("first_release_date")
                if ts and ts > 0:
                    try:
                        release_date = datetime.fromtimestamp(ts, tz=timezone.utc).strftime("%Y-%m-%d")
                    except (ValueError, OSError):
                        release_date = str(ts)

                results.append(ScraperResult(
                    title=item.get("name", ""),
                    description=(item.get("summary") or "")[:2000],
                    release_date=release_date,
                    cover_url=cover_url,
                    hero_url=hero,
                    screenshot_urls=shot_urls,
                    source_id=str(item.get("id", "")),
                    source_name=self.source_name,
                ))

        except httpx.HTTPError as e:
            logger.warning(f"IGDB search failed for '{name}': {e}")
        except Exception as e:
            logger.error(f"Unexpected error in IGDB: {e}")

        return results
