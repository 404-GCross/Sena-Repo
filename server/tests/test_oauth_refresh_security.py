import asyncio
import multiprocessing
import os
import tempfile
import unittest
from datetime import datetime, timedelta
from pathlib import Path
from unittest.mock import AsyncMock, patch

import httpx
from cryptography.fernet import Fernet
from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

import config
from database import Base
from models.user import User, UserOAuthBinding
from services import oauth_tokens as tokens
from services.oauth_providers import provider
from utils.secrets import decrypt_secret


def refresh_process(root, encryption_key, barrier, counter, queue):
    async def run():
        cfg = config.Config(data_path=root)
        engine = create_async_engine(cfg.database_url)
        sessions = async_sessionmaker(engine, expire_on_commit=False)
        original_snapshot = tokens._binding_snapshot
        first = True

        async def snapshot(*args):
            nonlocal first
            result = await original_snapshot(*args)
            if first:
                first = False
                await asyncio.to_thread(barrier.wait, 10)
            return result

        async def refresh(*args):
            with counter.get_lock():
                counter.value += 1
            await asyncio.sleep(0.1)
            return {"access_token": "process-access", "refresh_token": "process-refresh", "expires_in": 3600}

        try:
            with patch.object(config, "_cached_config", cfg), patch.dict(os.environ, {"SENA_ENCRYPTION_KEY": encryption_key}), patch.object(tokens, "_binding_snapshot", side_effect=snapshot), patch.object(tokens, "_refresh_tokens", side_effect=refresh):
                async with sessions() as session:
                    result = await tokens.get_provider_access_token(session, 1, "hikarinagi", force_refresh=True)
                queue.put(("ok", result == "process-access"))
        except BaseException as exc:
            queue.put(("error", type(exc).__name__))
        finally:
            await engine.dispose()
    asyncio.run(run())


class OAuthRefreshSecurityTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="sena-refresh-regression-")
        self.root = Path(self.temp.name).resolve()
        self.config = config.Config(data_path=str(self.root))
        self.key = Fernet.generate_key().decode()
        self.patches = [patch.object(config, "_cached_config", self.config), patch.dict(os.environ, {"SENA_ENCRYPTION_KEY": self.key})]
        for item in self.patches:
            item.start()
            self.addCleanup(item.stop)
        self.engine = create_async_engine(self.config.database_url)
        self.sessions = async_sessionmaker(self.engine, expire_on_commit=False)
        async with self.engine.begin() as connection:
            await connection.run_sync(lambda c: Base.metadata.create_all(c, tables=[User.__table__, UserOAuthBinding.__table__]))
        async with self.sessions() as session:
            for uid in (1, 2):
                session.add(User(id=uid, username=f"fixture-{uid}", salt="unused", password_hash="unused", status="active"))
                binding = UserOAuthBinding(user_id=uid, provider="hikarinagi", subject=f"fixture-subject-{uid}", oauth_user_id=uid)
                tokens.save_binding_tokens(binding, {"access_token": f"old-access-{uid}", "refresh_token": f"old-refresh-{uid}", "scope": "catalog:full user:read"})
                binding.expires_at = datetime.utcnow() - timedelta(seconds=1)
                session.add(binding)
            await session.commit()

    async def asyncTearDown(self):
        await self.engine.dispose()
        self.assertEqual(self.root, Path(self.temp.name).resolve())
        self.temp.cleanup()

    async def get(self, uid=1, *, force=False):
        async with self.sessions() as session:
            return await tokens.get_provider_access_token(session, uid, "hikarinagi", force_refresh=force)

    async def binding(self, session, uid=1):
        return (await session.execute(select(UserOAuthBinding).where(UserOAuthBinding.user_id == uid))).scalar_one()

    async def change(self, **values):
        async with self.sessions() as session:
            binding = await self.binding(session)
            for key, value in values.items():
                setattr(binding, key, value)
            await session.commit()

    async def winner(self, *, short=False):
        async with self.sessions() as session:
            binding = await self.binding(session)
            tokens.save_binding_tokens(binding, {"access_token": "winner-access", "refresh_token": "winner-refresh", "expires_in": 10 if short else 3600})
            await session.commit()

    async def test_ten_concurrent_forced_refreshes_use_one_rotating_request(self):
        entered, release = asyncio.Event(), asyncio.Event()
        calls = 0

        async def refresh(spec, refresh_token):
            nonlocal calls
            calls += 1
            self.assertEqual(refresh_token, "old-refresh-1")
            entered.set()
            await release.wait()
            return {"access_token": "new-access", "refresh_token": "new-refresh", "expires_in": 3600}

        with patch.object(tokens, "_refresh_tokens", side_effect=refresh):
            tasks = [asyncio.create_task(self.get(force=True)) for _ in range(10)]
            await asyncio.wait_for(entered.wait(), 2)
            await asyncio.sleep(0.1)
            release.set()
            self.assertEqual(await asyncio.wait_for(asyncio.gather(*tasks), 5), ["new-access"] * 10)
        self.assertEqual(calls, 1)
        self.assertLessEqual(len(list((self.root / ".oauth-refresh-locks").glob("*.lock"))), 256)

    async def test_different_bindings_refresh_in_parallel(self):
        both, release = asyncio.Event(), asyncio.Event()
        count = 0

        async def refresh(spec, refresh_token):
            nonlocal count
            count += 1
            if count == 2:
                both.set()
            await release.wait()
            return {"access_token": "parallel-access", "expires_in": 3600}

        with patch.object(tokens, "_refresh_tokens", side_effect=refresh):
            tasks = [asyncio.create_task(self.get(uid)) for uid in (1, 2)]
            try:
                await asyncio.wait_for(both.wait(), 2)
            finally:
                release.set()
            self.assertEqual(await asyncio.gather(*tasks), ["parallel-access"] * 2)

    async def test_rejection_recovers_newer_short_lived_success(self):
        async def refresh(*args):
            await self.winner(short=True)
            raise tokens.OAuthReauthRequired("fixture rejection")
        with patch.object(tokens, "_refresh_tokens", side_effect=refresh):
            self.assertEqual(await self.get(), "winner-access")

    async def test_success_cas_cannot_overwrite_a_new_authorization(self):
        async def refresh(*args):
            await self.winner()
            return {"access_token": "stale-access", "refresh_token": "stale-refresh", "expires_in": 3600}
        with patch.object(tokens, "_refresh_tokens", side_effect=refresh):
            self.assertEqual(await self.get(), "winner-access")
        async with self.sessions() as session:
            self.assertEqual(decrypt_secret((await self.binding(session)).refresh_token), "winner-refresh")

    async def test_unbind_and_rebind_during_request_cannot_be_overwritten(self):
        for mutation in ({"subject": None, "access_token": None, "refresh_token": None}, {"subject": "other-subject"}, {"oauth_user_id": 999}, {"created_at": datetime.utcnow() + timedelta(seconds=1)}):
            async with self.sessions() as session:
                original = await self.binding(session)
                saved = {key: getattr(original, key) for key in mutation}
            async def refresh(*args):
                await self.change(**mutation)
                return {"access_token": "stale-access", "refresh_token": "stale-refresh", "expires_in": 3600}
            with patch.object(tokens, "_refresh_tokens", side_effect=refresh):
                with self.assertRaises(tokens.OAuthReauthRequired):
                    await self.get()
            await self.change(**saved)

    async def test_deleted_binding_after_request_never_falls_back_to_app_credentials(self):
        async def refresh(*args):
            async with self.sessions() as session:
                await session.execute(delete(UserOAuthBinding).where(UserOAuthBinding.user_id == 1))
                await session.commit()
            raise tokens.OAuthReauthRequired("fixture rejection")
        with patch.object(tokens, "_refresh_tokens", side_effect=refresh):
            with self.assertRaises(tokens.OAuthReauthRequired):
                await self.get()
        self.assertIsNone(await self.get())

    async def test_waiter_cancellation_and_unbind_do_not_release_active_lock(self):
        entered, release = asyncio.Event(), asyncio.Event()
        async def refresh(*args):
            entered.set()
            await release.wait()
            return {"access_token": "new-access", "refresh_token": "new-refresh", "expires_in": 3600}
        with patch.object(tokens, "_refresh_tokens", side_effect=refresh) as upstream:
            active = asyncio.create_task(self.get())
            await asyncio.wait_for(entered.wait(), 2)
            waiter = asyncio.create_task(self.get())
            await asyncio.sleep(0.08)
            waiter.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await waiter
            await self.change(subject=None, access_token=None, refresh_token=None)
            release.set()
            with self.assertRaises(tokens.OAuthReauthRequired):
                await active
            self.assertEqual(upstream.call_count, 1)

    async def test_repeated_active_cancellation_joins_rotation_before_unlocking(self):
        entered, release = asyncio.Event(), asyncio.Event()
        async def refresh(*args):
            entered.set()
            await release.wait()
            return {"access_token": "new-access", "refresh_token": "new-refresh", "expires_in": 3600}
        with patch.object(tokens, "_refresh_tokens", side_effect=refresh) as upstream:
            active = asyncio.create_task(self.get())
            await asyncio.wait_for(entered.wait(), 2)
            active.cancel()
            await asyncio.sleep(0)
            active.cancel()
            waiter = asyncio.create_task(self.get())
            await asyncio.sleep(0.08)
            self.assertFalse(active.done())
            release.set()
            with self.assertRaises(asyncio.CancelledError):
                await active
            self.assertEqual(await waiter, "new-access")
            self.assertEqual(upstream.call_count, 1)
        async with self.sessions() as session:
            self.assertEqual(decrypt_secret((await self.binding(session)).refresh_token), "new-refresh")

    async def test_missing_refresh_and_transient_errors_preserve_state(self):
        for exc in (tokens.OAuthReauthRequired("fixture"), tokens.OAuthTokenError("fixture"), httpx.ReadTimeout("fixture")):
            with patch.object(tokens, "_refresh_tokens", side_effect=exc):
                with self.assertRaises(tokens.OAuthTokenError):
                    await self.get()
        await self.change(refresh_token=None)
        with self.assertRaises(tokens.OAuthReauthRequired):
            await self.get()

    async def test_omitted_refresh_and_scope_are_preserved(self):
        with patch.object(tokens, "_refresh_tokens", new=AsyncMock(return_value={"access_token": "new-access", "expires_in": 3600})):
            self.assertEqual(await self.get(), "new-access")
        async with self.sessions() as session:
            binding = await self.binding(session)
            self.assertEqual(decrypt_secret(binding.refresh_token), "old-refresh-1")
            self.assertEqual(binding.scope, "catalog:full user:read")

    async def test_stale_orm_instance_does_not_hide_newer_database_tokens(self):
        async with self.sessions() as session:
            old = await self.binding(session)
            await session.rollback()
            await self.winner()
            with patch.object(tokens, "_refresh_tokens") as upstream:
                self.assertEqual(await tokens.get_provider_access_token(session, 1, "hikarinagi"), "winner-access")
                upstream.assert_not_called()
            self.assertIsNotNone(old)

    async def test_malformed_expiry_and_scope_cannot_overwrite_tokens(self):
        for extra in [{"expires_in": value} for value in (10**100, float("inf"), True, "bad", -1, 0, None)] + [{"scope": ["user:read"]}]:
            with self.subTest(extra=extra):
                invalid = {"access_token": "bad-access", "refresh_token": "bad-refresh", **extra}
                with patch.object(tokens, "_refresh_tokens", new=AsyncMock(return_value=invalid)):
                    with self.assertRaises(tokens.OAuthTokenError):
                        await self.get()
                async with self.sessions() as session:
                    binding = await self.binding(session)
                    self.assertEqual(decrypt_secret(binding.refresh_token), "old-refresh-1")
        with patch.object(tokens, "_refresh_tokens", new=AsyncMock(return_value={"access_token": "valid", "expires_in": "3600"})):
            self.assertEqual(await self.get(), "valid")

    async def test_refresh_timeout_releases_lock_without_changing_identity(self):
        async def slow(*args):
            await asyncio.sleep(10)
        with patch.object(tokens, "_REFRESH_OPERATION_SECONDS", 0.01), patch.object(tokens, "_refresh_tokens", new=slow):
            with self.assertRaises(tokens.OAuthTokenError):
                await self.get()
        async with self.sessions() as session:
            self.assertEqual(decrypt_secret((await self.binding(session)).refresh_token), "old-refresh-1")
        with patch.object(tokens, "_refresh_tokens", new=AsyncMock(return_value={"access_token": "valid", "expires_in": 3600})):
            self.assertEqual(await self.get(), "valid")

    async def test_two_processes_share_refresh_serialization(self):
        ctx = multiprocessing.get_context("spawn")
        barrier, counter, queue = ctx.Barrier(2), ctx.Value("i", 0), ctx.Queue()
        processes = [ctx.Process(target=refresh_process, args=(str(self.root), self.key, barrier, counter, queue)) for _ in range(2)]
        for process in processes:
            process.start()
        try:
            for process in processes:
                await asyncio.to_thread(process.join, 15)
                self.assertEqual(process.exitcode, 0)
            self.assertEqual([queue.get(timeout=2) for _ in range(2)], [("ok", True)] * 2)
            self.assertEqual(counter.value, 1)
        finally:
            for process in processes:
                if process.is_alive():
                    process.terminate()
                    process.join(5)
            queue.close()

    async def test_upstream_invalid_responses_are_temporary_not_reauthorization(self):
        client_factory = httpx.AsyncClient
        for response in (httpx.Response(200, json=[]), httpx.Response(200, json={"access_token": 123}), httpx.Response(200, content=b"broken json"), httpx.Response(429), httpx.Response(503)):
            with patch.object(tokens.httpx, "AsyncClient", side_effect=lambda **kwargs: client_factory(transport=httpx.MockTransport(lambda request: response))):
                with self.assertRaises(tokens.OAuthTokenError) as result:
                    await tokens._refresh_tokens(provider("hikarinagi"), "fixture-refresh")
                self.assertNotIsInstance(result.exception, tokens.OAuthReauthRequired)


if __name__ == "__main__":
    unittest.main()
