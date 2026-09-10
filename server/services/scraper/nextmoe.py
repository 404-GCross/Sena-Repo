"""NextMoe scraper — six-source aggregated catalog via the open API v2."""

from __future__ import annotations

import logging

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

NEXTMOE_API_BASE = "https://api.nextmoe.dev/v2"
NEXTMOE_USER_AGENT = "SenaRepo/0.1 (https://github.com/404-GCross/Sena-Repo)"

_LIST_INCLUDE = "titles,companies,intros,covers,tags,ratings"
_DETAIL_INCLUDE = "screenshots"
_SEARCH_LIMIT = 5
_DETAIL_ENRICH_LIMIT = 3
_CHINESE_LANGS = ("zh-hans", "zh-cn", "zh-sg", "zh")
# Maker roles share the top rank so circle/brand credits beat a publisher.
_COMPANY_ROLE_RANK = {
    "developer": 0,
    "brand": 0,
    "circle": 0,
    "publisher": 1,
}


class NextMoeScraper(BaseScraper):
    """Scrape NextMoe's aggregated VNDB/Bangumi/DLsite catalog."""

    source_name = "nextmoe"
    max_retries = 2
    retry_delay = 1.5
    # Free tier allows 60 requests/minute.
    throttle_interval = 1.1

    def __init__(
        self,
        proxy: str = "",
        client: httpx.AsyncClient | None = None,
        api_key: str = "",
    ):
        super().__init__(proxy=proxy, client=client)
        self._api_key = api_key

    async def search(
        self,
        name: str,
        company_hint: str | None = None,
    ) -> list[ScraperResult]:
        keyword = clean_title(name)
        if not keyword:
            return []
        self._require_api_key()

        client_kwargs = {"timeout": httpx.Timeout(20.0)}
        if self.proxy:
            client_kwargs["proxy"] = self.proxy
        async with httpx.AsyncClient(**client_kwargs) as client:
            try:
                work_id = _normalize_work_id(keyword)
                if work_id:
                    detail = await self._get_work(client, work_id)
                    return [detail] if detail else []

                results: list[ScraperResult] = []
                for index, item in enumerate(await self._search_items(client, keyword)):
                    parsed = _parse_work(item)
                    if not parsed:
                        continue
                    if index < _DETAIL_ENRICH_LIMIT and parsed.source_id:
                        parsed = await self._get_work(
                            client, parsed.source_id, parsed
                        ) or parsed
                    results.append(parsed)
                return results
            except Exception as e:
                logger.warning("NextMoe search failed for '%s': %s", name, e)
                return []

    async def search_best(
        self,
        name: str,
        company_hint: str | None = None,
    ) -> ScraperResult | None:
        """Batch path: one list request per game, no per-record enrichment."""
        keyword = clean_title(name)
        if not keyword:
            return None
        self._require_api_key()

        client_kwargs = {"timeout": httpx.Timeout(20.0)}
        if self.proxy:
            client_kwargs["proxy"] = self.proxy
        async with httpx.AsyncClient(**client_kwargs) as client:
            try:
                work_id = _normalize_work_id(keyword)
                if work_id:
                    return await self._get_work(client, work_id)

                candidates = [
                    parsed
                    for item in await self._search_items(client, keyword)
                    if (parsed := _parse_work(item))
                ]
                return pick_best_scraper_result(keyword, candidates)
            except Exception as e:
                logger.warning("NextMoe search_best failed for '%s': %s", name, e)
                return None

    def _require_api_key(self) -> None:
        if not self._api_key.strip():
            raise RuntimeError("NextMoe API Key 未配置")

    def _headers(self) -> dict[str, str]:
        return {
            "Accept": "application/json",
            "Authorization": f"Bearer {self._api_key.strip()}",
            "User-Agent": NEXTMOE_USER_AGENT,
        }

    async def _api_get(
        self,
        client: httpx.AsyncClient,
        path: str,
        params: dict[str, str],
    ) -> dict:
        resp = await self._request_with_retry(
            client,
            "GET",
            f"{NEXTMOE_API_BASE}{path}",
            params=params,
            headers=self._headers(),
        )
        payload = resp.json()
        return payload if isinstance(payload, dict) else {}

    async def _search_items(
        self,
        client: httpx.AsyncClient,
        keyword: str,
    ) -> list[dict]:
        payload = await self._api_get(
            client,
            "/catalog/works",
            {
                "q": keyword,
                "limit": str(_SEARCH_LIMIT),
                "nsfw": "true",
                "include": _LIST_INCLUDE,
            },
        )
        items = payload.get("items")
        if not isinstance(items, list):
            return []
        return [item for item in items if isinstance(item, dict)]

    async def _get_work(
        self,
        client: httpx.AsyncClient,
        work_id: str,
        fallback: ScraperResult | None = None,
    ) -> ScraperResult | None:
        normalized_id = _normalize_work_id(work_id)
        if not normalized_id:
            return fallback
        params = {
            "nsfw": "true",
            "include": f"{_LIST_INCLUDE},{_DETAIL_INCLUDE}",
        }
        try:
            payload = await self._api_get(
                client, f"/catalog/works/{normalized_id}", params
            )
        except httpx.HTTPStatusError as e:
            merged_id = _merged_target(e)
            if not merged_id:
                if e.response.status_code == 404:
                    return fallback
                raise
            try:
                payload = await self._api_get(
                    client, f"/catalog/works/{merged_id}", params
                )
            except Exception:
                return fallback
        return _parse_work(payload) or fallback


def _parse_work(item: dict) -> ScraperResult | None:
    if not isinstance(item, dict):
        return None
    work_id = str(item.get("id") or "").strip()
    title = _work_title(item)
    if not work_id and not title:
        return None
    return ScraperResult(
        title=title,
        developer=_companies_label(item),
        description=_work_description(item),
        release_date=_normalize_date(item.get("release_date")),
        cover_url=_image_url(item.get("cover")),
        hero_url=_image_url(item.get("banner")),
        screenshot_urls=_image_urls(item.get("screenshots")),
        source_id=work_id,
        source_name=NextMoeScraper.source_name,
        is_nsfw=_content_rating_nsfw(item),
        tags=_work_tags(item),
    )


def _work_title(item: dict) -> str:
    return (
        _localized_title(item)
        or str(item.get("display_name") or "").strip()
        or str(item.get("latin") or "").strip()
    )


def _localized_title(item: dict) -> str:
    localized = item.get("localized")
    if not isinstance(localized, dict):
        return ""
    machine = ""
    for lang, entry in localized.items():
        value, is_machine = _localized_entry(entry)
        if not value:
            continue
        key = str(lang or "").strip().lower()
        if key not in _CHINESE_LANGS:
            continue
        if is_machine:
            machine = machine or value
        else:
            return value
    return machine


def _localized_entry(entry) -> tuple[str, bool]:
    if isinstance(entry, str):
        return entry.strip(), False
    if isinstance(entry, dict):
        value = str(entry.get("value") or entry.get("text") or "").strip()
        return value, bool(entry.get("is_machine"))
    return "", False


def _companies_label(item: dict) -> str:
    companies = item.get("companies")
    if not isinstance(companies, list):
        return ""
    ranked: list[tuple[int, str]] = []
    for index, entry in enumerate(companies):
        if isinstance(entry, str):
            name, role = entry.strip(), ""
        elif isinstance(entry, dict):
            name = str(
                entry.get("display_name") or entry.get("name") or ""
            ).strip()
            role = str(entry.get("attribution_role") or "").strip().lower()
        else:
            continue
        if not name:
            continue
        ranked.append((_COMPANY_ROLE_RANK.get(role, 2), name))
    ranked.sort(key=lambda pair: pair[0])
    names: list[str] = []
    for _, name in ranked:
        if name not in names:
            names.append(name)
    return ", ".join(names[:3])


def _work_description(item: dict) -> str:
    intros = item.get("intros")
    if not isinstance(intros, list):
        return ""
    fallback = ""
    for entry in intros:
        if isinstance(entry, str):
            text, lang = entry.strip(), ""
        elif isinstance(entry, dict):
            text = str(entry.get("intro") or entry.get("text") or "").strip()
            lang = str(entry.get("lang") or "").strip().lower()
        else:
            continue
        if not text:
            continue
        if lang.startswith("zh"):
            return text[:2000]
        fallback = fallback or text
    return fallback[:2000]


def _image_url(value) -> str:
    if isinstance(value, str):
        url = value.strip()
        return url if url.startswith(("http://", "https://")) else ""
    if isinstance(value, dict):
        for key in ("url", "image_url", "src"):
            url = _image_url(value.get(key))
            if url:
                return url
    return ""


def _image_urls(value) -> list[str]:
    if not isinstance(value, list):
        return []
    urls: list[str] = []
    for entry in value:
        url = _image_url(entry)
        if url and url not in urls:
            urls.append(url)
    return urls


def _content_rating_nsfw(item: dict) -> bool | None:
    rating = str(item.get("content_rating") or "").strip().lower()
    if rating == "r18":
        return True
    if rating in {"all_ages", "sensitive"}:
        return False
    return None


def _work_tags(item: dict) -> list[ScrapedTag]:
    tags = item.get("tags")
    if not isinstance(tags, list):
        return []
    result: list[ScrapedTag] = []
    seen: set[str] = set()
    for entry in tags:
        name, rating, spoiler = _parse_tag(entry)
        key = name.casefold()
        if not name or key in seen:
            continue
        seen.add(key)
        result.append(ScrapedTag(name=name, rating=rating, is_spoiler=spoiler))
    result.sort(key=lambda tag: tag.rating, reverse=True)
    return result[:MAX_SCRAPED_TAGS]


def _parse_tag(entry) -> tuple[str, float, bool]:
    if isinstance(entry, str):
        return entry.strip(), 0.0, False
    if isinstance(entry, dict):
        return (
            _tag_name(entry),
            _tag_rating(entry),
            _tag_spoiler(entry),
        )
    return "", 0.0, False


def _tag_name(entry: dict) -> str:
    name = entry.get("name")
    if isinstance(name, str) and name.strip():
        return name.strip()
    if isinstance(name, dict):
        for key in ("zh-cn", "zh-Hans", "zh-hans", "zh", "en", "ja"):
            value = name.get(key)
            if isinstance(value, str) and value.strip():
                return value.strip()
        for value in name.values():
            if isinstance(value, str) and value.strip():
                return value.strip()
    display = entry.get("display_name")
    if isinstance(display, str) and display.strip():
        return display.strip()
    return str(entry.get("slug") or "").strip()


def _tag_rating(entry: dict) -> float:
    for key in ("rating", "score", "votes", "count"):
        try:
            value = float(entry.get(key))
        except (TypeError, ValueError):
            continue
        if value:
            return value
    return 0.0


def _tag_spoiler(entry: dict) -> bool:
    value = entry.get("spoiler")
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        return value.strip().lower() not in {"", "none", "false", "0"}
    if isinstance(value, (int, float)):
        return value > 0
    return False


def _normalize_work_id(value: object) -> str:
    text = str(value or "").strip()
    if not text.isdigit():
        return ""
    return text if int(text) > 0 else ""


def _normalize_date(value: object) -> str:
    text = str(value or "").strip()
    if not text:
        return ""
    return text.split("T", 1)[0]


def _merged_target(exc: httpx.HTTPStatusError) -> str:
    if exc.response.status_code != 404:
        return ""
    try:
        body = exc.response.json()
    except Exception:
        return ""
    if not isinstance(body, dict) or body.get("code") != "ENTITY_MERGED":
        return ""
    return str(body.get("current_id") or "").strip()
