"""Abstract base class for metadata scrapers."""

from __future__ import annotations

import asyncio
from datetime import datetime, timezone
from difflib import SequenceMatcher
from email.utils import parsedate_to_datetime
import logging
import random
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
    cover_urls: list[str] = field(default_factory=list)  # cover candidates for picker
    screenshot_urls: list[str] = field(default_factory=list)  # all screenshots for picker
    external_ids: dict[str, str] = field(default_factory=dict)  # vndb/bangumi/steam anchors
    source_id: str = ""
    source_name: str = ""
    length: int = 0         # VNDB length category 1-5
    length_minutes: int = 0 # average play time in minutes
    is_nsfw: bool | None = None  # None means this source does not classify NSFW
    tags: list[ScrapedTag] = field(default_factory=list)
    aliases: list[str] = field(default_factory=list)  # alternative titles for search


def _parse_retry_after(value: str | None) -> float | None:
    """Parse a Retry-After header (seconds or HTTP date) into seconds."""
    if not value:
        return None
    text = value.strip()
    if not text:
        return None
    if text.isdigit():
        return float(text)
    try:
        when = parsedate_to_datetime(text)
    except (TypeError, ValueError):
        return None
    if when is None:
        return None
    if when.tzinfo is None:
        when = when.replace(tzinfo=timezone.utc)
    return max(0.0, (when - datetime.now(timezone.utc)).total_seconds())


def _is_quota_exceeded(resp: httpx.Response) -> bool:
    """Detect a 429 that carries a terminal QUOTA_EXCEEDED error code."""
    if resp.status_code != 429:
        return False
    try:
        payload = resp.json()
    except Exception:
        return False
    if not isinstance(payload, dict):
        return False
    code = str(payload.get("code") or "").strip().upper()
    if not code:
        error = payload.get("error")
        if isinstance(error, dict):
            code = str(error.get("code") or "").strip().upper()
    return code == "QUOTA_EXCEEDED"


class BaseScraper(ABC):
    """Base class for all metadata scrapers with retry and throttle support."""

    source_name: str = "base"
    max_retries: int = 2
    retry_delay: float = 1.5
    max_retry_delay: float = 30.0
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

    def _should_retry(self, resp: httpx.Response) -> bool:
        """Retry 429 and 5xx; other 4xx are terminal (quota errors included)."""
        if _is_quota_exceeded(resp):
            return False
        return resp.status_code == 429 or resp.status_code >= 500

    def _backoff_delay(
        self,
        attempt: int,
        resp: httpx.Response | None = None,
    ) -> float:
        """Exponential backoff with Retry-After support and jitter."""
        delay = self.retry_delay * (2**attempt)
        if resp is not None and resp.status_code == 429:
            retry_after = _parse_retry_after(resp.headers.get("Retry-After"))
            if retry_after is not None:
                delay = max(delay, retry_after)
        delay = min(delay, self.max_retry_delay)
        return delay * (0.8 + 0.4 * random.random())

    async def _request_with_retry(
        self,
        client: httpx.AsyncClient,
        method: str,
        url: str,
        **kwargs,
    ) -> httpx.Response:
        """Make an HTTP request with retry logic for transient errors."""
        last_error: Exception | None = None
        for attempt in range(self.max_retries + 1):
            try:
                await self._throttle()
                resp = await client.request(method, url, **kwargs)
            except httpx.TimeoutException as e:
                last_error = e
                if attempt < self.max_retries:
                    await asyncio.sleep(self._backoff_delay(attempt))
                    continue
                raise
            except Exception:
                raise
            if self._should_retry(resp):
                if attempt < self.max_retries:
                    await asyncio.sleep(self._backoff_delay(attempt, resp))
                    continue
            resp.raise_for_status()
            return resp
        raise last_error or RuntimeError(f"Request failed: {method} {url}")

    @abstractmethod
    async def search(
        self,
        name: str,
        company_hint: str | None = None,
        refs_hint: str | None = None,
    ) -> list[ScraperResult]:
        """Search for games matching the given name.

        `refs_hint` carries saved external anchors (`source:external_id`) for
        scrapers that can resolve them directly; other scrapers ignore it.
        """
        ...

    async def search_best(
        self,
        name: str,
        company_hint: str | None = None,
        refs_hint: str | None = None,
    ) -> ScraperResult | None:
        """Search and return the best (first) match, or None."""
        results = await self.search(name, company_hint, refs_hint)
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


def cover_candidates(
    rows: list[tuple[str, int, int, int]],
    primary: str = "",
    limit: int = 12,
) -> list[str]:
    """Order cover candidates for the picker.

    Rows carry (url, width, height, votes). Portrait covers come first, most
    voted first, and the source's base cover always leads.
    """
    portrait: list[tuple[int, str]] = []
    others: list[str] = []
    for url, width, height, votes in rows:
        if not url:
            continue
        if width and height and height > width:
            portrait.append((votes, url))
        else:
            others.append(url)
    portrait.sort(key=lambda item: item[0], reverse=True)
    ordered: list[str] = []
    for url in [primary, *[item[1] for item in portrait], *others]:
        if url and url not in ordered:
            ordered.append(url)
    return ordered[:limit]


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


# ── Alias utilities ──

ALIAS_SEPARATOR = "、"
MAX_ALIASES = 5
MAX_ALIAS_LENGTH = 200


def normalize_alias_key(value: str) -> str:
    normalized = unicodedata.normalize("NFKC", str(value or ""))
    return re.sub(r"\s+", " ", normalized).strip().casefold()


def build_alias_value(
    candidates: list[str],
    exclude: tuple[str, ...] = (),
    *,
    limit: int = MAX_ALIASES,
    max_length: int = MAX_ALIAS_LENGTH,
) -> str:
    """Deduplicate and join alias candidates for the single alias column."""
    excluded = {normalize_alias_key(value) for value in exclude if value}
    excluded.discard("")
    seen: set[str] = set()
    picked: list[str] = []
    for raw in candidates:
        text = re.sub(r"\s+", " ", str(raw or "")).strip()
        if not text:
            continue
        key = normalize_alias_key(text)
        if not key or key in excluded or key in seen or _is_noise_alias(key):
            continue
        seen.add(key)
        picked.append(text)
        if len(picked) >= limit:
            break
    result = ""
    for text in picked:
        merged = text if not result else f"{result}{ALIAS_SEPARATOR}{text}"
        if len(merged) > max_length:
            break
        result = merged
    return result


def _is_noise_alias(key: str) -> bool:
    if key.isdigit():
        return True
    return not any(ch.isalnum() for ch in key)
