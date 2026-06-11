"""Steam scraper — uses Store API + Community API (myGal approach)."""

from __future__ import annotations

import logging
from urllib.parse import quote as url_encode

import httpx

from .base import BaseScraper, ScraperResult, clean_title

logger = logging.getLogger(__name__)


class SteamScraper(BaseScraper):
    """Scrape Steam store for game metadata."""

    source_name = "steam"

    async def search(
        self,
        name: str,
        company_hint: str | None = None,
    ) -> list[ScraperResult]:
        keyword = clean_title(name)
        if not keyword:
            return []

        # Resolve App ID first (try Chinese store, then English)
        appid = await self._resolve_app_id(keyword)
        if not appid:
            return []

        # Fetch details + cover + vendors
        return await self._get_details(appid)

    async def _resolve_app_id(self, title: str) -> str | None:
        """Search Steam store for best matching App ID.

        Tries: Chinese store → English store → Steam Community search.
        """
        client_kwargs = {"timeout": httpx.Timeout(15.0)}
        if self.proxy:
            client_kwargs["proxy"] = self.proxy
        async with httpx.AsyncClient(**client_kwargs) as client:
            # Try 1: Chinese store
            appid = await self._store_search(client, title, "schinese", "CN")
            if appid:
                return appid
            # Try 2: English store
            appid = await self._store_search(client, title, "english", "US")
            if appid:
                return appid
            # Try 3: Steam Community
            appid = await self._community_search(client, title)
            return appid

    async def _store_search(
        self, client: httpx.AsyncClient, title: str, lang: str, cc: str
    ) -> str | None:
        try:
            resp = await self._request_with_retry(
                client, "GET",
                f"https://store.steampowered.com/api/storesearch/"
                f"?term={url_encode(title)}&l={lang}&cc={cc}&category1=998",
            )
            data = resp.json()
            items = data.get("items", [])
            if not items:
                return None
            picked = self._pick_best(items, title)
            return str(picked["id"]) if picked else None
        except Exception:
            return None

    async def _community_search(self, client: httpx.AsyncClient, title: str) -> str | None:
        try:
            resp = await self._request_with_retry(
                client, "GET",
                f"https://steamcommunity.com/actions/SearchApps/?term={url_encode(title)}",
            )
            apps = resp.json()
            if not isinstance(apps, list) or not apps:
                return None
            picked = self._pick_best(apps, title)
            return str(picked["appid"]) if picked else None
        except Exception:
            return None

    @staticmethod
    def _pick_best(items: list[dict], title: str) -> dict | None:
        """Pick best match: exact > contains > prefix > first."""
        norm = title.lower()
        # Exact match
        exact = next((a for a in items if str(a.get("name", "")).lower() == norm), None)
        if exact:
            return exact
        # Contains match (handles different language names)
        contains = next((a for a in items if norm in str(a.get("name", "")).lower()), None)
        if contains:
            return contains
        # Prefix match
        starts = next((a for a in items if str(a.get("name", "")).lower().startswith(norm)), None)
        if starts:
            return starts
        return items[0] if items else None

    async def _get_details(self, appid: str) -> list[ScraperResult]:
        """Fetch game details, cover, and vendors from App ID."""
        client_kwargs = {"timeout": httpx.Timeout(15.0)}
        if self.proxy:
            client_kwargs["proxy"] = self.proxy
        async with httpx.AsyncClient(**client_kwargs) as client:
            # Get app details for name + developer
            try:
                resp = await self._request_with_retry(
                    client, "GET",
                    f"https://store.steampowered.com/api/appdetails?appids={appid}&l=schinese",
                )
                data = resp.json()
                details = (data.get(str(appid)) or {}).get("data") or {}
            except Exception:
                details = {}

            title = details.get("name", "")
            devs = details.get("developers", [])
            developer = devs[0] if devs else ""
            description = (details.get("short_description") or "")[:500]

            # Cover URL: use primary CDN format directly (HEAD check often blocked in CN)
            cover_url = f"https://cdn.akamai.steamstatic.com/steam/apps/{appid}/library_600x900.jpg"

            # Ratings and genres
            rating = 0.0
            metacritic = (details.get("metacritic") or {}).get("score", 0)
            if metacritic > 0:
                rating = round(metacritic / 10.0, 1)
            else:
                # Fallback to review rating
                try:
                    r_resp = await client.get(
                        f"https://store.steampowered.com/appreviews/{appid}?json=1&language=all&"
                        f"purchase_type=all&num_per_page=0&filter=summary"
                    )
                    r_data = r_resp.json()
                    if r_data.get("success") == 1:
                        q = r_data.get("query_summary", {})
                        total = q.get("total_positive", 0) + q.get("total_negative", 0)
                        if total > 0:
                            rating = round(q["total_positive"] / total * 10, 1)
                except Exception:
                    pass

            genres = [g.get("description", "") for g in details.get("genres", []) if g.get("description")]
            if not genres:
                genres = [c.get("description", "") for c in details.get("categories", [])[:5] if c.get("description")]

            return [ScraperResult(
                title=title,
                developer=developer,
                description=description,
                release_date=(details.get("release_date") or {}).get("date", ""),
                cover_url=cover_url,
                source_id=appid,
                source_name=self.source_name,
            )] if title else []
