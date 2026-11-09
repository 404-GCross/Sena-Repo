from __future__ import annotations

import asyncio
import logging
import math
import time
from collections import OrderedDict, deque
from dataclasses import dataclass, field
from typing import Callable

import httpx

from config import load_config
from services.scraper.base import _parse_retry_after

logger = logging.getLogger(__name__)

MAX_BATCH_IDS = 100
MAX_BODY_BYTES = 16 * 1024
MAX_APP_ID = 4294967295
MAX_UPSTREAM_BYTES = 2 * 1024 * 1024


class SteamNamesLimited(Exception):
    def __init__(self, retry_after: int = 5):
        super().__init__("名称查询繁忙，请稍后重试")
        self.retry_after = max(1, retry_after)


class SteamNamesUnavailable(Exception):
    pass


@dataclass
class _UserBudget:
    requests: deque[float] = field(default_factory=deque)
    queries: deque[tuple[float, int]] = field(default_factory=deque)


@dataclass(frozen=True)
class _Result:
    name: str | None = None
    failed: bool = False
    limited: bool = False


@dataclass
class _Lookup:
    task: asyncio.Task[_Result]
    waiters: int = 0


def _http_client() -> httpx.AsyncClient:
    return httpx.AsyncClient(
        timeout=httpx.Timeout(10.0),
        proxy=load_config().proxy or None,
        follow_redirects=False,
    )


class SteamNameResolver:
    WINDOW = 60.0
    REQUESTS_PER_USER = 30
    QUERIES_PER_USER = 200
    QUERIES_GLOBAL = 500
    MAX_ACTIVE_BATCHES = 4
    MAX_USERS = 2048
    CACHE_SIZE = 4096
    SUCCESS_TTL = 24 * 60 * 60
    MISSING_TTL = 5 * 60
    BATCH_TIMEOUT = 60.0

    def __init__(
        self,
        *,
        client_factory: Callable[[], httpx.AsyncClient] = _http_client,
        clock: Callable[[], float] = time.monotonic,
    ):
        self._client_factory = client_factory
        self._clock = clock
        self._semaphore = asyncio.Semaphore(5)
        self._cache: OrderedDict[str, tuple[float, _Result]] = OrderedDict()
        self._pending: dict[str, _Lookup] = {}
        self._users: dict[int, _UserBudget] = {}
        self._global_queries: deque[tuple[float, int]] = deque()
        self._active_users: set[int] = set()
        self._cooldown_until = 0.0
        self._closed = False

    def _prune(self, now: float) -> None:
        cutoff = now - self.WINDOW
        while self._global_queries and self._global_queries[0][0] <= cutoff:
            self._global_queries.popleft()
        for key, budget in list(self._users.items()):
            while budget.requests and budget.requests[0] <= cutoff:
                budget.requests.popleft()
            while budget.queries and budget.queries[0][0] <= cutoff:
                budget.queries.popleft()
            if not budget.requests and not budget.queries and key not in self._active_users:
                del self._users[key]
        for key, (expires, _) in list(self._cache.items()):
            if expires <= now:
                del self._cache[key]

    def _request_budget(self, user_id: int, now: float) -> _UserBudget:
        self._prune(now)
        budget = self._users.get(user_id)
        if budget is None:
            if len(self._users) >= self.MAX_USERS:
                raise SteamNamesLimited()
            budget = self._users[user_id] = _UserBudget()
        if len(budget.requests) >= self.REQUESTS_PER_USER:
            raise SteamNamesLimited(math.ceil(budget.requests[0] + self.WINDOW - now))
        budget.requests.append(now)
        return budget

    def _query_retry(
        self, events: deque[tuple[float, int]], limit: int, cost: int, now: float
    ) -> int:
        remaining = sum(count for _, count in events) + cost
        if remaining <= limit:
            return 0
        for stamp, count in events:
            remaining -= count
            if remaining <= limit:
                return max(1, math.ceil(stamp + self.WINDOW - now))
        return math.ceil(self.WINDOW)

    def _remember(self, app_id: str, result: _Result) -> _Result:
        ttl = self.SUCCESS_TTL if result.name else self.MISSING_TTL
        self._cache[app_id] = (self._clock() + ttl, result)
        self._cache.move_to_end(app_id)
        while len(self._cache) > self.CACHE_SIZE:
            self._cache.popitem(last=False)
        return result

    async def _fetch(self, app_id: str) -> _Result:
        async with self._semaphore:
            if self._clock() < self._cooldown_until:
                return _Result(failed=True, limited=True)
            failed = False
            try:
                async with self._client_factory() as client:
                    for language in ("schinese", "english"):
                        if self._clock() < self._cooldown_until:
                            return _Result(failed=True, limited=True)
                        try:
                            async with client.stream(
                                "GET",
                                "https://store.steampowered.com/api/appdetails",
                                params={"appids": app_id, "l": language},
                            ) as response:
                                if response.status_code == 429:
                                    delay = _parse_retry_after(response.headers.get("Retry-After"))
                                    if delay is None or not math.isfinite(delay):
                                        delay = self.WINDOW
                                    self._cooldown_until = max(
                                        self._cooldown_until, self._clock() + max(1, delay)
                                    )
                                    logger.warning("Steam name upstream rate limited")
                                    return _Result(failed=True, limited=True)
                                if response.status_code != 200:
                                    failed = True
                                    continue
                                chunks = bytearray()
                                async for chunk in response.aiter_bytes():
                                    if len(chunks) + len(chunk) > MAX_UPSTREAM_BYTES:
                                        raise ValueError("response too large")
                                    chunks.extend(chunk)
                                payload = httpx.Response(200, content=bytes(chunks)).json()
                            entry = payload.get(app_id) if isinstance(payload, dict) else None
                            if not isinstance(entry, dict):
                                raise ValueError("invalid entry")
                            if entry.get("success") is False:
                                continue
                            data = entry.get("data")
                            name = data.get("name") if isinstance(data, dict) else None
                            if entry.get("success") is not True or not isinstance(name, str):
                                raise ValueError("invalid name")
                            if not name.strip() or len(name) > 512:
                                raise ValueError("invalid name")
                            return self._remember(app_id, _Result(name=name.strip()))
                        except (httpx.HTTPError, ValueError, TypeError) as exc:
                            failed = True
                            logger.warning(
                                "Steam name upstream failed: reason=%s", type(exc).__name__
                            )
            except Exception as exc:
                logger.warning("Steam name lookup failed: reason=%s", type(exc).__name__)
                return _Result(failed=True)
            if failed:
                return _Result(failed=True)
            return self._remember(app_id, _Result())

    async def resolve(self, user_id: int, app_ids: list[str]) -> dict[str, str]:
        if self._closed:
            raise SteamNamesUnavailable()
        now = self._clock()
        # Admission and reservations contain no awaits: atomic on the app event loop.
        budget = self._request_budget(user_id, now)
        results: dict[str, str] = {}
        missing: list[str] = []
        for app_id in dict.fromkeys(app_ids):
            cached = self._cache.get(app_id)
            if cached is None:
                missing.append(app_id)
            else:
                self._cache.move_to_end(app_id)
                if cached[1].name:
                    results[app_id] = cached[1].name
        if not missing:
            return results
        if now < self._cooldown_until:
            raise SteamNamesLimited(math.ceil(self._cooldown_until - now))
        if user_id in self._active_users or len(self._active_users) >= self.MAX_ACTIVE_BATCHES:
            raise SteamNamesLimited()
        fresh = [app_id for app_id in missing if app_id not in self._pending]
        retry = max(
            self._query_retry(budget.queries, self.QUERIES_PER_USER, len(fresh), now),
            self._query_retry(self._global_queries, self.QUERIES_GLOBAL, len(fresh), now),
        )
        if retry:
            raise SteamNamesLimited(retry)
        if fresh:
            budget.queries.append((now, len(fresh)))
            self._global_queries.append((now, len(fresh)))
        self._active_users.add(user_id)
        lookups: dict[str, _Lookup] = {}
        for app_id in missing:
            lookup = self._pending.get(app_id)
            if lookup is None:
                lookup = self._pending[app_id] = _Lookup(asyncio.create_task(self._fetch(app_id)))
            lookup.waiters += 1
            lookups[app_id] = lookup
        started = self._clock()
        try:
            done, pending = await asyncio.wait(
                {lookup.task for lookup in lookups.values()}, timeout=self.BATCH_TIMEOUT
            )
            failed = bool(pending)
            limited = False
            for app_id, lookup in lookups.items():
                if lookup.task not in done:
                    continue
                if lookup.task.cancelled():
                    failed = True
                    continue
                result = lookup.task.result()
                failed = failed or result.failed
                limited = limited or result.limited
                if result.name:
                    results[app_id] = result.name
            logger.info(
                "Steam names resolved: requested=%s cached=%s resolved=%s failed=%s duration_ms=%s",
                len(set(app_ids)), len(set(app_ids)) - len(missing), len(results), failed,
                round((self._clock() - started) * 1000),
            )
            if not results and limited:
                raise SteamNamesLimited(math.ceil(self._cooldown_until - self._clock()))
            if not results and failed:
                raise SteamNamesUnavailable()
            return results
        finally:
            cancelled = []
            for app_id, lookup in lookups.items():
                lookup.waiters -= 1
                if not lookup.waiters:
                    if self._pending.get(app_id) is lookup:
                        del self._pending[app_id]
                    if not lookup.task.done():
                        lookup.task.cancel()
                        cancelled.append(lookup.task)
            try:
                if cancelled:
                    await asyncio.gather(*cancelled, return_exceptions=True)
            finally:
                self._active_users.discard(user_id)

    async def close(self) -> None:
        self._closed = True
        tasks = [lookup.task for lookup in self._pending.values()]
        for task in tasks:
            task.cancel()
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)
        self._pending.clear()
        self._cache.clear()
        self._users.clear()
        self._global_queries.clear()
