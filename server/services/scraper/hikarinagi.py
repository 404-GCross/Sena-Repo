"""Hikarinagi scraper — OAuth2 client_credentials public catalog API."""

from __future__ import annotations

import logging
import time
from datetime import datetime

import httpx

from .base import (
    MAX_SCRAPED_TAGS,
    BaseScraper,
    ScrapedTag,
    ScraperResult,
    clean_title,
    pick_best_scraper_result,
)

logger = logging.getLogger(__name__)

HIKARINAGI_BASE = "https://www.hikarinagi.org/api/v3/open"
HIKARINAGI_CDN_BASE = "https://images.yurari.moe/"
HIKARINAGI_TOKEN_URL = "https://id.hikarinagi.org/oidc/token"


class HikarinagiScraper(BaseScraper):
    """Scrape Hikarinagi Galgame metadata."""

    source_name = "hikarinagi"
    max_retries = 2
    retry_delay = 1.2
    throttle_interval = 1.1

    def __init__(
        self,
        proxy: str = "",
        client: httpx.AsyncClient | None = None,
        client_id: str = "",
        client_secret: str = "",
        scope: str = "catalog:full",
    ):
        super().__init__(proxy=proxy, client=client)
        self._client_id = client_id
        self._client_secret = client_secret
        self._scope = scope or "catalog:full"
        self._token = ""
        self._token_expires = 0.0

    async def _ensure_token(self, client: httpx.AsyncClient) -> str:
        if not self._client_id or not self._client_secret:
            raise RuntimeError("Hikarinagi client_id/client_secret 未配置")

        now = time.monotonic()
        if self._token and now < self._token_expires:
            return self._token

        resp = await self._request_with_retry(
            client,
            "POST",
            HIKARINAGI_TOKEN_URL,
            data={
                "grant_type": "client_credentials",
                "scope": self._scope,
            },
            auth=httpx.BasicAuth(self._client_id, self._client_secret),
            headers={
                "Accept": "application/json",
                "Content-Type": "application/x-www-form-urlencoded",
            },
        )
        data = resp.json()
        token = data.get("access_token", "")
        if not token:
            raise RuntimeError("Hikarinagi Token 响应为空")
        expires_in = int(data.get("expires_in") or 3600)
        self._token = token
        refresh_before = 60 if expires_in > 60 else 0
        self._token_expires = now + max(0, expires_in - refresh_before)
        return token

    async def _api_get(
        self,
        client: httpx.AsyncClient,
        path: str,
        params: dict | list[tuple[str, str]] | None = None,
        use_auth: bool = False,
    ) -> dict:
        headers = {
            "Accept": "application/json",
            "User-Agent": "SenaRepo/0.1 (https://github.com/404-GCross/Sena-Repo)",
        }
        if use_auth:
            token = await self._ensure_token(client)
            headers["Authorization"] = f"Bearer {token}"
        for attempt in range(2):
            try:
                resp = await self._request_with_retry(
                    client,
                    "GET",
                    f"{HIKARINAGI_BASE}{path}",
                    params=params,
                    headers=headers,
                )
            except httpx.HTTPStatusError as e:
                if use_auth and e.response.status_code in (401, 403) and attempt == 0:
                    self._token = ""
                    token = await self._ensure_token(client)
                    headers["Authorization"] = f"Bearer {token}"
                    continue
                raise
            payload = resp.json()
            if not isinstance(payload, dict):
                return {}
            if payload.get("success") is False:
                request_id = payload.get("request_id")
                error = payload.get("error")
                if isinstance(error, dict):
                    message = error.get("message") or error.get("code")
                else:
                    message = payload.get("message") or error
                message = message or "Hikarinagi API 调用失败"
                if request_id:
                    message = f"{message} (request_id: {request_id})"
                raise RuntimeError(str(message))
            data = payload.get("data")
            return data if isinstance(data, dict) else {}
        return {}

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
                normalized_id = _normalize_hikarinagi_id(keyword)
                if normalized_id:
                    detail = await self._get_detail(client, normalized_id)
                    return [detail] if detail else []

                hits = await self._search_hits(client, keyword, page_size=5)
                results: list[ScraperResult] = []
                for hit in hits:
                    fallback = self._parse_hit(hit)
                    if not fallback:
                        continue
                    try:
                        detail = await self._get_detail(client, fallback.source_id, fallback)
                    except Exception as e:
                        logger.debug(
                            "Hikarinagi detail failed for '%s': %s",
                            fallback.source_id,
                            e,
                        )
                        detail = fallback
                    if detail:
                        results.append(detail)
                return results
            except Exception as e:
                logger.warning("Hikarinagi search failed for '%s': %s", name, e)
                return []

    async def search_best(
        self,
        name: str,
        company_hint: str | None = None,
    ) -> ScraperResult | None:
        keyword = clean_title(name)
        if not keyword:
            return None

        client_kwargs = {"timeout": httpx.Timeout(15.0)}
        if self.proxy:
            client_kwargs["proxy"] = self.proxy
        async with httpx.AsyncClient(**client_kwargs) as client:
            try:
                normalized_id = _normalize_hikarinagi_id(keyword)
                if normalized_id:
                    return await self._get_detail(client, normalized_id)

                fallbacks = [
                    fallback
                    for hit in await self._search_hits(client, keyword, page_size=5)
                    if (fallback := self._parse_hit(hit))
                ]
                fallback = pick_best_scraper_result(keyword, fallbacks)
                if not fallback:
                    return None
                return await self._get_detail(client, fallback.source_id, fallback)
            except Exception as e:
                logger.warning("Hikarinagi search_best failed for '%s': %s", name, e)
                return None

    async def _search_hits(
        self,
        client: httpx.AsyncClient,
        keyword: str,
        page_size: int,
    ) -> list[dict]:
        data = await self._api_get(
            client,
            "/search",
            params=[
                ("q", keyword),
                ("types", "galgame"),
                ("page", "1"),
                ("page_size", str(page_size)),
            ],
            use_auth=True,
        )
        items = data.get("items")
        if not isinstance(items, list):
            return []
        return [item for item in items if isinstance(item, dict) and item.get("type") == "galgame"]

    async def _get_detail(
        self,
        client: httpx.AsyncClient,
        game_id: str,
        fallback: ScraperResult | None = None,
    ) -> ScraperResult | None:
        normalized_id = _normalize_hikarinagi_id(game_id)
        if not normalized_id:
            return fallback
        data = await self._api_get(
            client,
            f"/galgames/{normalized_id}",
            use_auth=True,
        )
        if not data:
            return fallback
        return self._parse_detail(data, fallback)

    def _parse_hit(self, item: dict) -> ScraperResult | None:
        source_id = str(item.get("id") or "").strip()
        if not source_id:
            return None
        return ScraperResult(
            title=(item.get("title") or item.get("subtitle") or "").strip(),
            developer=(item.get("developer") or "").strip(),
            cover_url=_media_url(item.get("cover")),
            source_id=source_id,
            source_name=self.source_name,
            is_nsfw=bool(item.get("nsfw", False)),
        )

    def _parse_detail(self, item: dict, fallback: ScraperResult | None) -> ScraperResult:
        title = (
            item.get("trans_title")
            or item.get("origin_title")
            or (fallback.title if fallback else "")
            or ""
        )
        description = (
            item.get("trans_intro")
            or item.get("origin_intro")
            or (fallback.description if fallback else "")
            or ""
        )
        covers = item.get("covers") if isinstance(item.get("covers"), list) else []
        images = item.get("images") if isinstance(item.get("images"), list) else []
        cover_url = _best_cover(covers) or (fallback.cover_url if fallback else "")
        screenshots = [_media_url(img) for img in images]
        screenshots = [url for url in screenshots if url]
        hero_url = screenshots[0] if screenshots else ""
        nsfw_value = item.get("nsfw")
        if nsfw_value is None and fallback is not None:
            nsfw_value = fallback.is_nsfw
        tags = _tags_from_detail(item)

        return ScraperResult(
            title=title.strip(),
            developer=_developer_from_detail(item) or (fallback.developer if fallback else ""),
            description=description.strip()[:2000],
            release_date=_normalize_date(
                item.get("release_date") or (fallback.release_date if fallback else "") or ""
            ),
            cover_url=cover_url,
            hero_url=hero_url,
            screenshot_urls=screenshots,
            source_id=str(item.get("id") or (fallback.source_id if fallback else "") or "").strip(),
            source_name=self.source_name,
            is_nsfw=bool(nsfw_value) if nsfw_value is not None else None,
            tags=tags,
        )


def _normalize_hikarinagi_id(value: str) -> str:
    text = str(value or "").strip()
    try:
        parsed = int(text)
    except ValueError:
        return ""
    return str(parsed) if parsed > 0 else ""


def _media_url(value) -> str:
    if not value:
        return ""
    if isinstance(value, str):
        url = value.strip()
        if not url:
            return ""
        if url.startswith(("http://", "https://")):
            return url
        return f"{HIKARINAGI_CDN_BASE}{url.lstrip('/')}"
    if isinstance(value, dict):
        for key in ("url", "image", "src"):
            url = _media_url(value.get(key))
            if url:
                return url
        media = value.get("media")
        if isinstance(media, dict):
            return _media_url(media)
    return ""


def _best_cover(covers: list) -> str:
    candidates = [cover for cover in covers if isinstance(cover, dict) and _media_url(cover)]
    if not candidates:
        return ""
    best = max(candidates, key=_cover_votes)
    return _media_url(best)


def _cover_votes(cover: dict) -> int:
    try:
        return int(cover.get("votes") or 0)
    except (TypeError, ValueError):
        return 0


def _normalize_date(value: str) -> str:
    text = str(value or "").strip()
    if not text:
        return ""
    try:
        return datetime.fromisoformat(text.replace("Z", "+00:00")).date().isoformat()
    except ValueError:
        return text


def _developer_from_detail(item: dict) -> str:
    for key in ("developer", "producer", "brand", "developers", "producers", "brands", "companies"):
        value = item.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
        if isinstance(value, list):
            names = []
            for entry in value:
                if isinstance(entry, str) and entry.strip():
                    names.append(entry.strip())
                elif isinstance(entry, dict):
                    name = entry.get("trans_name") or entry.get("name") or entry.get("title")
                    if name:
                        names.append(str(name).strip())
            if names:
                return ", ".join(names[:3])
    return ""


def _tags_from_detail(item: dict) -> list[ScrapedTag]:
    values = item.get("tags")
    if not isinstance(values, list):
        return []

    result: list[ScrapedTag] = []
    seen: set[str] = set()
    for entry in values:
        if isinstance(entry, str):
            name = entry.strip()
            likes = 0.0
        elif isinstance(entry, dict):
            name = str(
                entry.get("name")
                or entry.get("trans_name")
                or entry.get("title")
                or ""
            ).strip()
            likes = _tag_likes(entry.get("likes"))
        else:
            continue
        key = name.casefold()
        if not name or key in seen:
            continue
        seen.add(key)
        result.append(ScrapedTag(name=name, rating=likes))
    result.sort(key=lambda tag: tag.rating, reverse=True)
    return result[:MAX_SCRAPED_TAGS]


def _tag_likes(value: object) -> float:
    try:
        return float(value or 0)
    except (TypeError, ValueError):
        return 0.0
