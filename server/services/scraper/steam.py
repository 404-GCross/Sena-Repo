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

        # Search all stores, then pick best App ID across all of them
        appid = await self._resolve_app_id(keyword)
        if not appid:
            return []

        # Fetch details + cover + vendors
        return await self._get_details(appid, keyword)

    async def _resolve_app_id(self, title: str) -> str | None:
        """Search all Steam stores and pick the best matching App ID.

        Collects candidates from Chinese store, English store, and Community search,
        then picks the best match across all sources.
        """
        client_kwargs = {"timeout": httpx.Timeout(15.0)}
        if self.proxy:
            client_kwargs["proxy"] = self.proxy
        logger.debug(f"Steam resolve_app_id '{title}': creating client...")
        async with httpx.AsyncClient(**client_kwargs) as client:
            all_items: list[dict] = []

            # Collect from all sources
            for lang, cc in [("schinese", "CN"), ("english", "US")]:
                logger.debug(f"Steam resolve_app_id '{title}': searching store l={lang} cc={cc}")
                items = await self._store_search(client, title, lang, cc)
                logger.debug(f"Steam resolve_app_id '{title}': store l={lang} returned {len(items) if items else 0} items")
                if items:
                    all_items.extend(items)

            # Community search as additional source (only if store searches found nothing)
            if not all_items:
                logger.debug(f"Steam resolve_app_id '{title}': searching community")
                comm_items = await self._community_search(client, title)
                logger.debug(f"Steam resolve_app_id '{title}': community returned {len(comm_items) if comm_items else 0} items")
                if comm_items:
                    all_items.extend(comm_items)

            if not all_items:
                return None

            # Pick best match across ALL results
            picked = self._pick_best(all_items, title)
            if picked is None:
                return None

            # Community results use "appid", store results use "id"
            appid = picked.get("appid") or picked.get("id")
            return str(appid) if appid else None

    async def _store_search(
        self, client: httpx.AsyncClient, title: str, lang: str, cc: str
    ) -> list[dict] | None:
        try:
            resp = await self._request_with_retry(
                client, "GET",
                f"https://store.steampowered.com/api/storesearch/"
                f"?term={url_encode(title)}&l={lang}&cc={cc}&category1=998",
            )
            data = resp.json()
            items = data.get("items", [])
            return items if items else None
        except Exception:
            return None

    async def _community_search(self, client: httpx.AsyncClient, title: str) -> list[dict] | None:
        try:
            resp = await self._request_with_retry(
                client, "GET",
                f"https://steamcommunity.com/actions/SearchApps/?term={url_encode(title)}",
            )
            apps = resp.json()
            if not isinstance(apps, list) or not apps:
                return None
            return apps
        except Exception:
            return None

    @staticmethod
    def _pick_best(items: list[dict], title: str) -> dict | None:
        """Pick best match by name similarity. Only returns results that
        contain or start with the search title — no blind fallback to first."""
        norm = title.lower()
        # Exact match
        exact = next((a for a in items if str(a.get("name", "")).lower() == norm), None)
        if exact:
            return exact
        # Contains match (handles different language / subtitle variations)
        contains = next((a for a in items if norm in str(a.get("name", "")).lower()), None)
        if contains:
            return contains
        # Prefix match
        starts = next((a for a in items if str(a.get("name", "")).lower().startswith(norm)), None)
        if starts:
            return starts
        # Search term is contained in item name (reverse contains — handles
        # cases where store name is longer / has extra info)
        for a in items:
            item_name = str(a.get("name", "")).lower()
            if item_name and item_name in norm:
                return a
        return None

    async def _get_details(self, appid: str, search_title: str = "") -> list[ScraperResult]:
        """Fetch game details, cover, and vendors from App ID.

        Tries Chinese store first, falls back to English for region-locked games.
        """
        client_kwargs = {"timeout": httpx.Timeout(15.0)}
        if self.proxy:
            client_kwargs["proxy"] = self.proxy
        async with httpx.AsyncClient(**client_kwargs) as client:
            # Try Chinese store first, fall back to English
            details = {}
            for lang in ("schinese", "english"):
                try:
                    resp = await self._request_with_retry(
                        client, "GET",
                        f"https://store.steampowered.com/api/appdetails?appids={appid}&l={lang}",
                    )
                    data = resp.json()
                    details = (data.get(str(appid)) or {}).get("data") or {}
                    if details.get("name"):
                        break  # Got a valid result
                except Exception:
                    continue

            if not details:
                return []

            title = details.get("name", "")
            if not title:
                return []

            devs = details.get("developers", [])
            developer = devs[0] if devs else ""
            description = (details.get("short_description") or "")[:500]

            # Cover URL: prefer Chinese → English → default
            cover_url = f"https://cdn.akamai.steamstatic.com/steam/apps/{appid}/library_600x900.jpg"
            # Try Chinese-specific covers first
            for suffix in ("_schinese", "_english", ""):
                try:
                    url = f"https://cdn.akamai.steamstatic.com/steam/apps/{appid}/library_600x900{suffix}.jpg"
                    r = await client.head(url)
                    if r.status_code == 200:
                        cover_url = url
                        break
                except Exception:
                    continue

            # Hero banner (landscape): library_hero.jpg (1920x620) is best, fall back to header.jpg
            hero_url = f"https://cdn.akamai.steamstatic.com/steam/apps/{appid}/library_hero.jpg"
            try:
                r = await client.head(hero_url)
                if r.status_code != 200:
                    hero_url = f"https://cdn.akamai.steamstatic.com/steam/apps/{appid}/header.jpg"
            except Exception:
                hero_url = f"https://cdn.akamai.steamstatic.com/steam/apps/{appid}/header.jpg"

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
                hero_url=hero_url,
                source_id=appid,
                source_name=self.source_name,
            )] if title else []
