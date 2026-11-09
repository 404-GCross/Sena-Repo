import asyncio
import unittest

import httpx
from fastapi import FastAPI, Request
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from api.auth import _issue_session_token
from api.steam_patch import router
from database import Base, get_session
from models.user import User, UserOAuthBinding, UserSession
from services.steam_names import (
    MAX_BODY_BYTES, MAX_UPSTREAM_BYTES,
    SteamNameResolver, SteamNamesLimited, SteamNamesUnavailable,
)


def name_response(request, name=None):
    app_id = request.url.params["appids"]
    return httpx.Response(200, json={
        app_id: {"success": True, "data": {"name": name or f"Game {app_id}"}}
    })


class ResolverTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.now = 1000.0
        self.calls = []
        self.handler = lambda request: name_response(request)

        async def upstream(request):
            self.calls.append(request)
            result = self.handler(request)
            return await result if asyncio.iscoroutine(result) else result

        self.resolver = SteamNameResolver(
            client_factory=lambda: httpx.AsyncClient(transport=httpx.MockTransport(upstream)),
            clock=lambda: self.now,
        )

    async def asyncTearDown(self):
        await self.resolver.close()

    async def test_deduplicate_and_cache_public_names(self):
        result = await self.resolver.resolve(1, ["1", "1", "2"])
        self.assertEqual(result, {"1": "Game 1", "2": "Game 2"})
        self.assertEqual(len(self.calls), 2)
        self.assertEqual(await self.resolver.resolve(2, ["1", "2"]), result)
        self.assertEqual(len(self.calls), 2)
        self.assertTrue(all(str(r.url).startswith("https://store.steampowered.com/") for r in self.calls))
        self.assertTrue(all("authorization" not in r.headers for r in self.calls))

    async def test_chinese_first_and_english_fallback(self):
        def handler(request):
            if request.url.params["l"] == "schinese":
                return httpx.Response(200, json={"1": {"success": False}})
            return name_response(request, "English name")

        self.handler = handler
        self.assertEqual(await self.resolver.resolve(1, ["1"]), {"1": "English name"})
        self.assertEqual([r.url.params["l"] for r in self.calls], ["schinese", "english"])

    async def test_confirmed_missing_is_cached_briefly(self):
        self.handler = lambda r: httpx.Response(200, json={"1": {"success": False}})
        self.assertEqual(await self.resolver.resolve(1, ["1"]), {})
        self.assertEqual(await self.resolver.resolve(2, ["1"]), {})
        self.assertEqual(len(self.calls), 2)
        self.now += self.resolver.MISSING_TTL + 1
        self.assertEqual(await self.resolver.resolve(1, ["1"]), {})
        self.assertEqual(len(self.calls), 4)

    async def test_cache_expiry_and_lru_capacity(self):
        self.resolver.CACHE_SIZE = 2
        await self.resolver.resolve(1, ["1", "2"])
        await self.resolver.resolve(1, ["1"])
        await self.resolver.resolve(1, ["3"])
        self.assertEqual(list(self.resolver._cache), ["1", "3"])
        await self.resolver.resolve(1, ["2"])
        self.assertEqual(len(self.calls), 4)
        self.now += self.resolver.SUCCESS_TTL + 1
        await self.resolver.resolve(1, ["2"])
        self.assertEqual(len(self.calls), 5)

    async def test_transient_errors_do_not_poison_cache(self):
        for response in (
            httpx.Response(503), httpx.Response(200, text="not json"),
            httpx.Response(200, json={}),
            httpx.Response(200, json={"1": {"success": True, "data": {"name": []}}}),
            httpx.Response(200, content=b"x" * (MAX_UPSTREAM_BYTES + 1)),
        ):
            with self.subTest(status=response.status_code):
                self.handler = lambda r: response
                with self.assertRaises(SteamNamesUnavailable):
                    await self.resolver.resolve(1, ["1"])
                self.assertNotIn("1", self.resolver._cache)
        self.handler = lambda r: name_response(r)
        self.assertEqual(await self.resolver.resolve(1, ["1"]), {"1": "Game 1"})

    async def test_timeout_and_partial_success(self):
        def handler(request):
            if request.url.params["appids"] == "2":
                raise httpx.ReadTimeout("local simulated timeout", request=request)
            return name_response(request)

        self.handler = handler
        self.assertEqual(await self.resolver.resolve(1, ["1", "2"]), {"1": "Game 1"})
        self.assertNotIn("2", self.resolver._cache)
        with self.assertRaises(SteamNamesUnavailable):
            await self.resolver.resolve(1, ["2"])

    async def test_upstream_rate_limit_sets_shared_cooldown(self):
        await self.resolver.resolve(1, ["1"])
        self.handler = lambda r: httpx.Response(429, headers={"Retry-After": "90"})
        with self.assertRaises(SteamNamesLimited) as limited:
            await self.resolver.resolve(1, ["2"])
        self.assertEqual(limited.exception.retry_after, 90)
        with self.assertRaises(SteamNamesLimited):
            await self.resolver.resolve(2, ["3"])
        self.assertEqual(await self.resolver.resolve(2, ["1"]), {"1": "Game 1"})
        self.assertEqual(len(self.calls), 2)
        self.now += 91
        self.handler = lambda r: name_response(r)
        self.assertEqual(await self.resolver.resolve(2, ["2"]), {"2": "Game 2"})

    async def test_user_and_global_query_budgets(self):
        self.resolver.QUERIES_PER_USER = 2
        self.resolver.QUERIES_GLOBAL = 3
        await self.resolver.resolve(1, ["1", "2"])
        await self.resolver.resolve(1, ["1"])
        with self.assertRaises(SteamNamesLimited) as limited:
            await self.resolver.resolve(1, ["3"])
        self.assertEqual(limited.exception.retry_after, 60)
        await self.resolver.resolve(2, ["3"])
        with self.assertRaises(SteamNamesLimited):
            await self.resolver.resolve(3, ["4"])
        self.assertEqual(len(self.calls), 3)
        self.now += 61
        await self.resolver.resolve(1, ["4"])
        self.assertEqual(len(self.calls), 4)

    async def test_request_rate_includes_cache_hits_and_empty_requests(self):
        await self.resolver.resolve(1, ["1"])
        for _ in range(29):
            await self.resolver.resolve(1, [])
        with self.assertRaises(SteamNamesLimited) as limited:
            await self.resolver.resolve(1, ["1"])
        self.assertEqual(limited.exception.retry_after, 60)
        self.assertEqual(len(self.calls), 1)
        self.now += 61
        await self.resolver.resolve(1, ["1"])
        self.assertEqual(len(self.calls), 1)

    async def test_user_budget_records_are_bounded_and_expire(self):
        self.resolver.MAX_USERS = 2
        await self.resolver.resolve(1, [])
        await self.resolver.resolve(2, [])
        with self.assertRaises(SteamNamesLimited):
            await self.resolver.resolve(3, [])
        self.assertEqual(len(self.resolver._users), 2)
        self.now += 61
        await self.resolver.resolve(3, [])
        self.assertEqual(list(self.resolver._users), [3])

    async def test_all_batches_share_five_upstream_slots(self):
        active = peak = 0
        full = asyncio.Event()
        release = asyncio.Event()

        async def handler(request):
            nonlocal active, peak
            active += 1
            peak = max(active, peak)
            if active == 5:
                full.set()
            try:
                await release.wait()
                return name_response(request)
            finally:
                active -= 1

        self.handler = handler
        tasks = [asyncio.create_task(self.resolver.resolve(i, [str(i * 2 + 1), str(i * 2 + 2)])) for i in range(4)]
        try:
            await asyncio.wait_for(full.wait(), 2)
            self.assertEqual(active, 5)
            release.set()
            await asyncio.gather(*tasks)
            self.assertEqual(peak, 5)
        finally:
            release.set()
            await asyncio.gather(*tasks, return_exceptions=True)

    async def test_batch_admission_is_bounded_per_user_and_globally(self):
        admitted = asyncio.Event()
        release = asyncio.Event()

        async def handler(request):
            if len(self.calls) == 4:
                admitted.set()
            await release.wait()
            return name_response(request)

        self.handler = handler
        tasks = [asyncio.create_task(self.resolver.resolve(i, [str(i + 1)])) for i in range(4)]
        try:
            await asyncio.wait_for(admitted.wait(), 2)
            for user in (0, 4):
                with self.assertRaises(SteamNamesLimited):
                    await self.resolver.resolve(user, ["99"])
            self.assertEqual(len(self.calls), 4)
            release.set()
            await asyncio.gather(*tasks)
            await self.resolver.resolve(4, ["99"])
        finally:
            release.set()
            await asyncio.gather(*tasks, return_exceptions=True)

    async def test_shared_lookup_survives_one_waiter_cancelling(self):
        entered = asyncio.Event()
        release = asyncio.Event()

        async def handler(request):
            entered.set()
            await release.wait()
            return name_response(request)

        self.handler = handler
        first = asyncio.create_task(self.resolver.resolve(1, ["1"]))
        second = asyncio.create_task(self.resolver.resolve(2, ["1"]))
        try:
            await asyncio.wait_for(entered.wait(), 2)
            self.assertEqual(self.resolver._pending["1"].waiters, 2)
            first.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await first
            release.set()
            self.assertEqual(await second, {"1": "Game 1"})
            self.assertEqual(len(self.calls), 1)
            self.assertEqual(sum(n for _, n in self.resolver._global_queries), 1)
        finally:
            release.set()
            await asyncio.gather(first, second, return_exceptions=True)
        self.assertFalse(self.resolver._pending)
        self.assertFalse(self.resolver._active_users)

    async def test_last_waiter_cancellation_releases_resources(self):
        entered = asyncio.Event()
        stopped = asyncio.Event()

        async def handler(request):
            entered.set()
            try:
                await asyncio.Event().wait()
            finally:
                stopped.set()

        self.handler = handler
        task = asyncio.create_task(self.resolver.resolve(1, ["1"]))
        await asyncio.wait_for(entered.wait(), 2)
        task.cancel()
        with self.assertRaises(asyncio.CancelledError):
            await task
        self.assertTrue(stopped.is_set())
        self.assertFalse(self.resolver._pending)
        self.assertFalse(self.resolver._active_users)
        self.assertEqual(self.resolver._semaphore._value, 5)

    async def test_batch_deadline_returns_partial_and_cancels_unshared_work(self):
        self.resolver.BATCH_TIMEOUT = 0.05

        async def handler(request):
            if request.url.params["appids"] == "2":
                await asyncio.Event().wait()
            return name_response(request)

        self.handler = handler
        self.assertEqual(await self.resolver.resolve(1, ["1", "2"]), {"1": "Game 1"})
        self.assertFalse(self.resolver._pending)
        self.assertFalse(self.resolver._active_users)
        with self.assertRaises(SteamNamesUnavailable):
            await self.resolver.resolve(1, ["2"])

    async def test_shutdown_cancels_outstanding_work(self):
        entered = asyncio.Event()

        async def handler(request):
            entered.set()
            await asyncio.Event().wait()

        self.handler = handler
        task = asyncio.create_task(self.resolver.resolve(1, ["1"]))
        await asyncio.wait_for(entered.wait(), 2)
        await self.resolver.close()
        with self.assertRaises(SteamNamesUnavailable):
            await task
        with self.assertRaises(SteamNamesUnavailable):
            await self.resolver.resolve(1, [])
        self.assertFalse(self.resolver._pending)
        self.assertFalse(self.resolver._active_users)


class NameEndpointTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.calls = []

        def upstream(request):
            self.calls.append(request)
            return name_response(request)

        self.resolver = SteamNameResolver(
            client_factory=lambda: httpx.AsyncClient(transport=httpx.MockTransport(upstream))
        )
        self.engine = create_async_engine("sqlite+aiosqlite:///:memory:")
        self.sessions = async_sessionmaker(self.engine, expire_on_commit=False)
        async with self.engine.begin() as conn:
            await conn.run_sync(lambda c: Base.metadata.create_all(
                c, tables=[User.__table__, UserOAuthBinding.__table__, UserSession.__table__]
            ))
        self.auth = {}
        async with self.sessions() as session:
            for role in ("admin", "user"):
                user = User(username=role, password_hash="unused", salt="unused", role=role, status="active")
                session.add(user)
                await session.flush()
                self.auth[role] = {"Authorization": "Bearer " + await _issue_session_token(user, session)}
            await session.commit()

        async def session_dependency():
            async with self.sessions() as session:
                yield session

        app = self.app = FastAPI()
        app.state.steam_names = self.resolver
        app.include_router(router)
        app.dependency_overrides[get_session] = session_dependency

        @app.post("/unrelated")
        async def unrelated(request: Request):
            return {"bytes": len(await request.body())}

        self.client = httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://testserver")

    async def asyncTearDown(self):
        await self.client.aclose()
        await self.resolver.close()
        await self.engine.dispose()

    async def post(self, ids, role="user"):
        return await self.client.post("/api/steam/game-names", json={"appids": ids}, headers=self.auth[role])

    async def test_admin_and_user_allowed_anonymous_rejected(self):
        for role in ("admin", "user"):
            response = await self.post(["1"], role)
            self.assertEqual(response.status_code, 200, response.text)
        response = await self.client.post("/api/steam/game-names", json={"appids": ["2"]})
        self.assertEqual(response.status_code, 401)
        self.assertEqual(len(self.calls), 1)

    async def test_empty_maximum_batch_and_original_length_limit(self):
        self.assertEqual((await self.post([])).json(), {})
        response = await self.post([str(i) for i in range(1, 101)])
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(len(response.json()), 100)
        for ids in (["1"] * 101, [str(i) for i in range(1, 102)]):
            self.assertEqual((await self.post(ids)).status_code, 422)
        self.assertEqual(len(self.calls), 100)

    async def test_strict_id_validation_happens_before_upstream(self):
        for value in ("0", "-1", "01", " 1", "1\n", "1 ", "4294967296", "12345678901", "１２", "1&l=english", "https://example.invalid", "", 1, True, None):
            with self.subTest(value=value):
                response = await self.post([value])
                self.assertEqual(response.status_code, 422, response.text)
        self.assertFalse(self.calls)
        response = await self.post(["4294967295", "4294967295"])
        self.assertEqual(response.status_code, 200)
        self.assertEqual(len(self.calls), 1)

    async def test_large_body_is_rejected_even_with_false_content_length(self):
        response = await self.client.post(
            "/api/steam/game-names", content=b" " * (MAX_BODY_BYTES + 1),
            headers={**self.auth["user"], "Content-Type": "application/json", "Content-Length": "1"},
        )
        self.assertEqual(response.status_code, 413, response.text)
        self.assertFalse(self.calls)

    async def test_chunked_body_is_bounded_and_other_routes_unchanged(self):
        async def chunks():
            yield b" " * (MAX_BODY_BYTES // 2)
            yield b" " * (MAX_BODY_BYTES // 2 + 1)

        response = await self.client.post("/api/steam/game-names", content=chunks(), headers=self.auth["user"])
        self.assertEqual(response.status_code, 413)
        self.assertFalse(self.calls)
        response = await self.client.post("/unrelated", content=b" " * (MAX_BODY_BYTES + 1))
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["bytes"], MAX_BODY_BYTES + 1)

    async def test_rate_limit_returns_retry_after_without_upstream(self):
        for _ in range(30):
            self.assertEqual((await self.post([])).status_code, 200)
        response = await self.post(["1"])
        self.assertEqual(response.status_code, 429)
        self.assertGreater(int(response.headers["Retry-After"]), 0)
        self.assertFalse(self.calls)

    async def test_upstream_failure_is_502_not_missing_cache(self):
        self.resolver._client_factory = lambda: httpx.AsyncClient(
            transport=httpx.MockTransport(lambda r: httpx.Response(503))
        )
        response = await self.post(["1"])
        self.assertEqual(response.status_code, 502)
        self.assertFalse(self.resolver._cache)
