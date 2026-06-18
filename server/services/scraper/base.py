"""Abstract base class for metadata scrapers."""

from __future__ import annotations

import asyncio
import logging
import re
import time
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from pathlib import Path

import httpx

logger = logging.getLogger(__name__)

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
        return results[0] if results else None


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
    # Strip common version/edition suffixes
    t = re.sub(r"[-_ ]?v?\d+\.?\d*$", "", t)
    t = re.sub(r"[-_ ]?(汉化|中文|官方中文|完全版|DL版|体験版|体験版Ver[\d.]+).*$", "", t)
    t = re.sub(r"[-_ ]?[（(][^)）]*[)）]$", "", t)
    return t.strip()


def extract_dlsite_workno(name: str) -> str | None:
    """Extract DLsite work number (RJ/VJ/BJ/RE + 6-8 digits)."""
    m = re.search(r"((?:RJ|VJ|BJ|RE)\d{6,8})", name, re.IGNORECASE)
    return m.group(1) if m else None
