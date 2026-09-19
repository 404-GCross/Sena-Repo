"""Steam scraper — uses Store API + Community API (myGal approach)."""

from __future__ import annotations

import json
import logging
from urllib.parse import quote as url_encode

import httpx

from .base import (
    MAX_SCRAPED_TAGS,
    BaseScraper,
    ScrapedTag,
    ScraperResult,
    clean_title,
    title_match_score,
)

logger = logging.getLogger(__name__)

STEAM_ASSET_BASE_URL = "https://shared.akamai.steamstatic.com/store_item_assets/"
STEAM_STORE_ITEMS_URL = "https://api.steampowered.com/IStoreBrowseService/GetItems/v1/"


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

        # If keyword is a numeric App ID, skip store search, go direct
        if keyword.isdigit():
            return await self._get_details(keyword, keyword)

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
        """Pick best match by title score without blindly accepting sequels."""
        ranked = sorted(
            (
                (title_match_score(title, str(item.get("name", ""))), index, item)
                for index, item in enumerate(items)
            ),
            key=lambda item: (-item[0], item[1]),
        )
        if not ranked:
            return None
        score, _, item = ranked[0]
        return item if score >= 70 else None

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

            cover_url = await self._resolve_cover_url(client, appid)

            # Background: prefer the Store API image, then fall back to CDN assets.
            header_url = f"https://cdn.akamai.steamstatic.com/steam/apps/{appid}/header.jpg"
            hero_url = details.get("header_image") or header_url
            if not details.get("header_image"):
                library_hero_url = f"https://cdn.akamai.steamstatic.com/steam/apps/{appid}/library_hero.jpg"
                try:
                    r = await client.head(library_hero_url)
                    if r.status_code == 200:
                        hero_url = library_hero_url
                except Exception:
                    pass

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

            tag_names: list[str] = []
            seen_tags: set[str] = set()
            for entry in [*(details.get("genres") or []), *(details.get("categories") or [])]:
                name = str(entry.get("description", "")).strip() if isinstance(entry, dict) else ""
                key = name.casefold()
                if not name or key in seen_tags:
                    continue
                seen_tags.add(key)
                tag_names.append(name)
            tags = [ScrapedTag(name=name) for name in tag_names[:MAX_SCRAPED_TAGS]]

            return [ScraperResult(
                title=title,
                developer=developer,
                description=description,
                release_date=(details.get("release_date") or {}).get("date", ""),
                cover_url=cover_url,
                hero_url=hero_url,
                source_id=appid,
                source_name=self.source_name,
                tags=tags,
            )] if title else []

    async def _resolve_cover_url(self, client: httpx.AsyncClient, appid: str) -> str:
        assets = await self._get_store_assets(client, appid)
        for key in ("library_capsule_2x", "library_capsule"):
            url = self._build_store_asset_url(assets, key)
            if url:
                return url

        for suffix in ("_schinese", "_english", ""):
            try:
                url = (
                    f"https://cdn.akamai.steamstatic.com/steam/apps/{appid}/"
                    f"library_600x900{suffix}.jpg"
                )
                r = await client.head(url)
                if r.status_code == 200:
                    return url
            except Exception:
                continue
        return ""

    async def _get_store_assets(
        self,
        client: httpx.AsyncClient,
        appid: str,
    ) -> dict[str, str]:
        appid_int = int(appid) if appid.isdigit() else None
        if appid_int is None:
            return {}

        for lang, cc in (("schinese", "CN"), ("english", "US")):
            payload = {
                "ids": [{"appid": appid_int}],
                "context": {
                    "language": lang,
                    "country_code": cc,
                    "steam_realm": 1,
                },
                "data_request": {
                    "include_assets": True,
                    "include_basic_info": True,
                },
            }
            url = (
                STEAM_STORE_ITEMS_URL
                + "?input_json="
                + url_encode(json.dumps(payload, separators=(",", ":")), safe="")
            )
            try:
                resp = await self._request_with_retry(client, "GET", url)
                items = (resp.json().get("response") or {}).get("store_items") or []
                if not items:
                    continue
                assets = items[0].get("assets") or {}
                if isinstance(assets, dict):
                    return {
                        str(key): str(value)
                        for key, value in assets.items()
                        if value is not None
                    }
            except Exception as e:
                logger.debug(f"Steam asset lookup failed for app {appid} ({lang}): {e}")
        return {}

    @staticmethod
    def _build_store_asset_url(assets: dict[str, str], key: str) -> str:
        filename = (assets.get(key) or "").strip()
        template = (assets.get("asset_url_format") or "").strip()
        if not filename or not template:
            return ""
        path = template.replace("${FILENAME}", filename)
        if path.startswith("http://") or path.startswith("https://"):
            return path
        return STEAM_ASSET_BASE_URL + path.lstrip("/")
