"""Abstract base class for metadata scrapers."""

from __future__ import annotations

import logging
from abc import ABC, abstractmethod
from dataclasses import dataclass, field

import httpx

logger = logging.getLogger(__name__)


@dataclass
class ScraperResult:
    """Result from a scraper query."""

    title: str = ""
    developer: str = ""
    description: str = ""
    release_date: str = ""
    cover_url: str = ""
    # Source-specific IDs
    source_id: str = ""
    source_name: str = ""


class BaseScraper(ABC):
    """Base class for all metadata scrapers.

    Each scraper takes a game name + optional hints (like company tag)
    and returns a ScraperResult with metadata from that source.
    """

    source_name: str = "base"

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

    @abstractmethod
    async def search(
        self,
        name: str,
        company_hint: str | None = None,
    ) -> list[ScraperResult]:
        """Search for games matching the given name.

        Args:
            name: Game name to search for.
            company_hint: Optional company/developer name to narrow results.

        Returns:
            List of matching scraper results, best match first.
        """
        ...

    async def search_best(
        self,
        name: str,
        company_hint: str | None = None,
    ) -> ScraperResult | None:
        """Search and return the best (first) match, or None."""
        results = await self.search(name, company_hint)
        return results[0] if results else None
