"""月幕GalGame (ymgal.games) scraper — OAuth2 REST API with Chinese titles."""

from __future__ import annotations

import logging
import time

import httpx

from .base import BaseScraper, ScraperResult, clean_title

logger = logging.getLogger(__name__)

YMGAL_BASE = "https://www.ymgal.games"


class YmgalScraper(BaseScraper):
    """Scrape 月幕GalGame (ymgal.games) for Chinese-focused GalGame metadata."""

    source_name = "ymgal"
    max_retries = 2
    retry_delay = 1.2
    throttle_interval = 0.9

    def __init__(
        self,
        proxy: str = "",
        client: httpx.AsyncClient | None = None,
        client_id: str = "ymgal",
        client_secret: str = "luna0327",
    ):
        super().__init__(proxy=proxy, client=client)
        self._token: str = ""
        self._token_expires: float = 0.0
        self._client_id = client_id
        self._client_secret = client_secret

    async def _ensure_token(self, client: httpx.AsyncClient) -> str:
        """Get or refresh OAuth2 access token."""
        now = time.monotonic()
        if self._token and now < self._token_expires:
            return self._token

        resp = await client.get(
            f"{YMGAL_BASE}/oauth/token",
            params={
                "grant_type": "client_credentials",
                "client_id": self._client_id,
                "client_secret": self._client_secret,
                "scope": "public",
            },
            headers={"Accept": "application/json;charset=utf-8"},
        )
        resp.raise_for_status()
        data = resp.json()
        self._token = data.get("access_token", "")
        expires_in = data.get("expires_in", 3600)
        self._token_expires = now + max(300, expires_in - 60)
        if not self._token:
            raise Exception("月幕Gal Token 响应为空")
        return self._token

    async def _api_get(
        self, client: httpx.AsyncClient, path: str, params: dict | None = None
    ) -> dict:
        """Make an authenticated GET request to the YMGAL API."""
        token = await self._ensure_token(client)
        headers = {
            "Accept": "application/json;charset=utf-8",
            "Authorization": f"Bearer {token}",
            "version": "1",
            "User-Agent": "SenaRepo/0.1 (GalGame manager)",
        }
        # Try once; on 401/403 refresh token and retry
        for attempt in range(2):
            try:
                resp = await self._request_with_retry(
                    client, "GET", f"{YMGAL_BASE}{path}",
                    params=params, headers=headers,
                )
            except httpx.HTTPStatusError as e:
                if e.response.status_code in (401, 403) and attempt == 0:
                    self._token = ""
                    token = await self._ensure_token(client)
                    headers["Authorization"] = f"Bearer {token}"
                    continue
                raise
            data = resp.json()
            code = data.get("code", -1)
            if code != 0 and not data.get("success", False):
                if code in (401, 403) and attempt == 0:
                    self._token = ""
                    token = await self._ensure_token(client)
                    headers["Authorization"] = f"Bearer {token}"
                    continue
                msg = data.get("msg", "调用失败")
                raise Exception(f"月幕Gal API {code}: {msg}")
            return data.get("data") or {}
        return {}  # unreachable

    async def search(
        self,
        name: str,
        company_hint: str | None = None,
    ) -> list[ScraperResult]:
        keyword = clean_title(name)
        if not keyword:
            return []

        client_kwargs = {"timeout": httpx.Timeout(15.0)}
        if self.proxy:
            client_kwargs["proxy"] = self.proxy
        async with httpx.AsyncClient(**client_kwargs) as client:
            try:
                data = await self._api_get(client, "/open/archive/search-game", {
                    "mode": "list",
                    "keyword": keyword,
                    "pageNum": "1",
                    "pageSize": "5",
                })
            except Exception as e:
                logger.warning(f"月幕Gal search failed for '{name}': {e}")
                return []

            results_raw = data.get("result") or []
            results: list[ScraperResult] = []
            for item in results_raw:
                if not isinstance(item, dict):
                    continue
                r = self._parse_list_item(item)
                if r and r.source_id:
                    results.append(r)
            return results

    async def search_best(
        self,
        name: str,
        company_hint: str | None = None,
    ) -> ScraperResult | None:
        results = await self.search(name, company_hint)
        if not results:
            return None
        # Fetch detail for richer data (description)
        best = results[0]
        try:
            client_kwargs = {"timeout": httpx.Timeout(15.0)}
            if self.proxy:
                client_kwargs["proxy"] = self.proxy
            async with httpx.AsyncClient(**client_kwargs) as client:
                data = await self._api_get(client, "/open/archive", {"gid": best.source_id})
                game = data.get("game") or {}
                if game:
                    return self._parse_game(game, best)
        except Exception as e:
            logger.debug(f"月幕Gal detail failed for '{best.source_id}': {e}")
        return best

    def _parse_list_item(self, o: dict) -> ScraperResult | None:
        gid = o.get("gid") or o.get("id", "")
        if not gid:
            return None
        roman = o.get("name", "")
        chinese = o.get("chineseName", "")
        title = chinese or roman
        cover = _normalize_image(o.get("mainImg", ""))
        return ScraperResult(
            title=title.strip(),
            developer=(o.get("orgName") or "").strip(),
            release_date=(o.get("releaseDate") or "").strip(),
            cover_url=cover,
            source_id=str(gid).strip(),
            source_name=self.source_name,
        )

    def _parse_game(self, game: dict, base: ScraperResult) -> ScraperResult:
        roman = game.get("name", "") or base.title
        chinese = game.get("chineseName", "")
        title = chinese or roman
        cover = _normalize_image(game.get("mainImg", "")) or base.cover_url
        description = (game.get("introduction") or "").strip().replace("\r", "")[:2000]
        return ScraperResult(
            title=title.strip(),
            developer=(game.get("orgName") or base.developer or "").strip(),
            description=description,
            release_date=(game.get("releaseDate") or base.release_date or "").strip(),
            cover_url=cover,
            source_id=base.source_id,
            source_name=self.source_name,
        )


def _normalize_image(url: str) -> str:
    if not url:
        return ""
    u = url.strip()
    if u.startswith("//"):
        return "https:" + u
    return u
