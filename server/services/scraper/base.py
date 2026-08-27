"""Abstract base class for metadata scrapers."""

from __future__ import annotations

import asyncio
from difflib import SequenceMatcher
import logging
import re
import time
import unicodedata
from abc import ABC, abstractmethod
from dataclasses import dataclass, field

import httpx

logger = logging.getLogger(__name__)

MAX_SCRAPED_TAGS = 20

# Simple in-memory throttle to prevent hammering APIs
_last_request_time: float = 0
_throttle_lock: asyncio.Lock | None = None
_throttle_lock_loop_id: int | None = None


def _get_throttle_lock() -> asyncio.Lock:
    """Return a lock bound to the current event loop (creates new one if loop changed)."""
    global _throttle_lock, _throttle_lock_loop_id
    try:
        current_loop_id = id(asyncio.get_running_loop())
    except RuntimeError:
        return asyncio.Lock()  # No running loop, just create one
    if _throttle_lock is None or _throttle_lock_loop_id != current_loop_id:
        _throttle_lock = asyncio.Lock()
        _throttle_lock_loop_id = current_loop_id
    return _throttle_lock


@dataclass
class ScrapedTag:
    """Tag metadata returned by an upstream scraper."""

    name: str
    rating: float = 0.0
    is_spoiler: bool = False


@dataclass
class ScraperResult:
    """Result from a scraper query."""

    title: str = ""
    developer: str = ""
    description: str = ""
    release_date: str = ""
    cover_url: str = ""
    hero_url: str = ""   # wide landscape banner (Steam header.jpg, etc.)
    screenshot_urls: list[str] = field(default_factory=list)  # all screenshots for picker
    source_id: str = ""
    source_name: str = ""
    length: int = 0         # VNDB length category 1-5
    length_minutes: int = 0 # average play time in minutes
    is_nsfw: bool | None = None  # None means this source does not classify NSFW
    tags: list[ScrapedTag] = field(default_factory=list)


class BaseScraper(ABC):
    """Base class for all metadata scrapers with retry and throttle support."""

    source_name: str = "base"
    max_retries: int = 2
    retry_delay: float = 1.5
    throttle_interval: float = 1.0  # seconds between requests

    def __init__(self, proxy: str = "", client: httpx.AsyncClient | None = None):
        self.proxy = proxy
        self._client = client
        self._own_client = False

    async def _get_client(self) -> httpx.AsyncClient:
        if self._client is None:
            kwargs = {"timeout": httpx.Timeout(30.0)}
            if self.proxy:
                kwargs["proxy"] = self.proxy
            self._client = httpx.AsyncClient(**kwargs)
            self._own_client = True
        return self._client

    async def close(self):
        if self._own_client and self._client:
            await self._client.aclose()
            self._client = None

    async def _throttle(self):
        """Ensure minimum interval between requests to avoid rate limits."""
        global _last_request_time
        async with _get_throttle_lock():
            elapsed = time.monotonic() - _last_request_time
            if elapsed < self.throttle_interval:
                await asyncio.sleep(self.throttle_interval - elapsed)
            _last_request_time = time.monotonic()

    async def _request_with_retry(
        self,
        client: httpx.AsyncClient,
        method: str,
        url: str,
        **kwargs,
    ) -> httpx.Response:
        """Make an HTTP request with retry logic for transient errors."""
        last_error = None
        for attempt in range(self.max_retries + 1):
            try:
                await self._throttle()
                resp = await client.request(method, url, **kwargs)
                if resp.status_code in (429, 503):
                    if attempt < self.max_retries:
                        await asyncio.sleep(self.retry_delay * (attempt + 1))
                        continue
                resp.raise_for_status()
                return resp
            except (httpx.TimeoutException, httpx.HTTPStatusError) as e:
                last_error = e
                if attempt < self.max_retries:
                    await asyncio.sleep(self.retry_delay * (attempt + 1))
                    continue
                raise
            except Exception:
                raise
        raise last_error  # type: ignore

    @abstractmethod
    async def search(
        self,
        name: str,
        company_hint: str | None = None,
    ) -> list[ScraperResult]:
        """Search for games matching the given name."""
        ...

    async def search_best(
        self,
        name: str,
        company_hint: str | None = None,
    ) -> ScraperResult | None:
        """Search and return the best (first) match, or None."""
        results = await self.search(name, company_hint)
        if _looks_like_source_id(name):
            return results[0] if results else None
        return pick_best_scraper_result(name, results)


# ── Title cleaning utilities ──

def clean_title(title: str) -> str:
    """Clean a game title for better scraper matching.

    Removes platform markers, version numbers, and suffixes.
    Pure numeric IDs (Steam appid, etc.) are returned as-is.
    """
    t = title.strip()
    if not t:
        return ""
    # Pure numeric → likely an app ID (Steam, VNDB, etc.), don't strip
    if re.match(r"^\d+$", t):
        return t
    # Strip platform markers: [PC], (KRKR), 【Ty】, 直装_, etc.
    t = re.sub(r"^[\[\(（][A-Za-z]+[\]\)）]", "", t).strip()
    t = re.sub(r"^直装[_ ]", "", t, flags=re.IGNORECASE).strip()
    # Strip common version/edition suffixes. Do not remove plain trailing
    # digits: they are often sequel numbers, e.g. 猫忍えくすはーと2.
    t = re.sub(
        r"[-_ ]?(?:v|ver|version)\s*\d+(?:\.\d+)*$",
        "",
        t,
        flags=re.IGNORECASE,
    )
    t = re.sub(r"[-_ ]?\d+\.\d+(?:\.\d+)*$", "", t)
    t = re.sub(
        r"[-_ ]?(汉化|中文|官方中文|完全版|DL版|体験版|体験版Ver[\d.]+).*$",
        "",
        t,
        flags=re.IGNORECASE,
    )
    t = re.sub(
        r"[-_ ]?[（(](?:pc|krkr|ons|ty|android|直装|汉化|中文|官方中文|dl版|"
        r"r18|r-18|成人|全年龄|全年齡|ver[\d.]+|v[\d.]+)[)）]$",
        "",
        t,
        flags=re.IGNORECASE,
    )
    return t.strip()


def title_search_key(title: str) -> str:
    normalized = unicodedata.normalize("NFKC", title).casefold()
    return "".join(ch for ch in normalized if ch.isalnum())


def normalized_title_search_key(title: str) -> str:
    return re.sub(
        r"\d+",
        lambda match: _normalize_number_group(match.group(0)),
        title_search_key(title),
    )


def title_number_groups(title: str) -> tuple[str, ...]:
    return tuple(
        _normalize_number_group(value)
        for value in re.findall(r"\d+", title_search_key(title))
    )


def title_match_score(query: str, title: str) -> int:
    query_key = normalized_title_search_key(clean_title(query))
    title_key = normalized_title_search_key(title)
    if not query_key or not title_key:
        return 0

    query_numbers = title_number_groups(query_key)
    title_numbers = title_number_groups(title_key)
    if query_numbers and title_numbers and query_numbers != title_numbers:
        return 0

    if query_key == title_key:
        score = 100
    elif title_key.startswith(query_key) or query_key.startswith(title_key):
        score = 92
    elif query_key in title_key or title_key in query_key:
        score = 88
    else:
        score = round(SequenceMatcher(None, query_key, title_key).ratio() * 86)

    if query_numbers and not title_numbers:
        score = min(score, 62)
    elif title_numbers and not query_numbers:
        score = min(score, 66)
    return max(0, min(100, score))


def pick_best_scraper_result(
    query: str,
    results: list[ScraperResult],
    *,
    min_score: int = 70,
) -> ScraperResult | None:
    if not results:
        return None
    ranked = sorted(
        (
            (title_match_score(query, result.title), index, result)
            for index, result in enumerate(results)
        ),
        key=lambda item: (-item[0], item[1]),
    )
    score, _, result = ranked[0]
    return result if score >= min_score else None


def rank_scraper_results(
    query: str,
    results: list[ScraperResult],
) -> list[ScraperResult]:
    return [
        result
        for _, _, result in sorted(
            (
                (title_match_score(query, result.title), index, result)
                for index, result in enumerate(results)
            ),
            key=lambda item: (-item[0], item[1]),
        )
    ]


def _looks_like_source_id(value: str) -> bool:
    query = value.strip().lower()
    return bool(re.fullmatch(r"(?:v|bgm|steam|hn)?\d+", query))


def _normalize_number_group(value: str) -> str:
    normalized = value.lstrip("0")
    return normalized or "0"
