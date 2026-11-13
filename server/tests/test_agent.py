import json
import os
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import AsyncMock, patch

import httpx
from cryptography.fernet import Fernet
from fastapi import FastAPI
from sqlalchemy import select
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

import config
import database
from api import agent, auth
from database import Base, get_session
from models.agent import AgentConfig, AgentJob, AgentResult
from models.game import Game, GameVersion
from models.root_directory import RootDirectory
from models.file_source import SteamPatchRoot
from models.user import User
from schemas.agent import AgentSettings
from services.agent.inventory import archive_evidence, inventory, relative_path
from services.agent.jobs import run_job
from services.agent.providers import ModelClient, ModelError, tool_spec
from services.agent.runtime import AgentBudget, AgentStopped, Runtime, object_schema
from services.agent.settings import client_options, load_settings, save_settings
from services.scraper.base import ScraperResult


class FakeScraper:
    source_name = "steam"

    async def search(self, query):
        return [
            ScraperResult(
                title="Test Game",
                source_name="steam",
                source_id="123",
                developer="Studio",
                description="Verified description",
                aliases=["测试游戏"],
            )
        ]

    async def search_best(self, *args, **kwargs):
        return (await self.search(""))[0]

    async def close(self):
        pass


class AgentTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.config = config.Config(data_path=self.tmp.name)
        self.config._scan_depth = 0
        for p in [
            patch.object(config, "_cached_config", self.config),
            patch.dict(
                os.environ, {"SENA_ENCRYPTION_KEY": Fernet.generate_key().decode()}
            ),
        ]:
            p.start()
            self.addCleanup(p.stop)
        self.engine = create_async_engine("sqlite+aiosqlite:///:memory:")
        self.sessions = async_sessionmaker(self.engine, expire_on_commit=False)
        async with self.engine.begin() as conn:
            await conn.run_sync(Base.metadata.create_all)
        p = patch.object(database, "_session_factory", self.sessions)
        p.start()
        self.addCleanup(p.stop)
        self.app = FastAPI()
        self.app.include_router(agent.router)

        async def session_dependency():
            async with self.sessions() as session:
                yield session

        self.app.dependency_overrides[get_session] = session_dependency
        async with self.sessions() as session:
            user = User(
                username="admin-test",
                password_hash="unused",
                salt="unused",
                role="admin",
                status="active",
            )
            session.add(user)
            await session.flush()
            token = await auth._issue_session_token(user, session)
            self.user_id = user.id
            await session.commit()
        self.headers = {"Authorization": "Bearer " + token}
        self.client = httpx.AsyncClient(
            transport=httpx.ASGITransport(self.app), base_url="http://test"
        )

    async def asyncTearDown(self):
        await self.client.aclose()
        await self.engine.dispose()

    async def configure(self, **kwargs):
        value = AgentSettings(enabled=True, model="test-model", **kwargs)
        async with self.sessions() as session:
            await save_settings(session, value)
        return value

    async def test_admin_only_and_default_off(self):
        self.assertEqual(
            (await self.client.get("/api/agent/settings")).status_code, 401
        )
        data = (
            await self.client.get("/api/agent/settings", headers=self.headers)
        ).json()
        self.assertFalse(data["enabled"])
        self.assertTrue(data["patch_steam_name"])
        self.assertTrue(data["game_ask"])
        async with self.sessions() as session:
            user = await session.get(User, self.user_id)
            user.role = "user"
            await session.commit()
        for method, path, body in [
            ("GET", "/settings", None),
            ("POST", "/test", None),
            ("GET", "/models", None),
            ("GET", "/jobs", None),
            ("POST", "/jobs", {"kind": "game"}),
        ]:
            response = await self.client.request(
                method, "/api/agent" + path, json=body, headers=self.headers
            )
            self.assertEqual(response.status_code, 403)

    async def test_secrets_are_encrypted_and_omitted(self):
        await self.configure(
            api_key="private-key",
            proxy_mode="custom",
            proxy_url="http://proxy.invalid:8080",
            proxy_password="private-password",
        )
        response = await self.client.get("/api/agent/settings", headers=self.headers)
        self.assertNotIn("private-key", response.text)
        self.assertNotIn("private-password", response.text)
        self.assertTrue(response.json()["has_api_key"])
        async with self.sessions() as session:
            row = await session.get(AgentConfig, 1)
            self.assertTrue(row.settings["api_key"].startswith("enc:v1:"))
            value, _ = await load_settings(session)
            value.api_key = None
            await save_settings(session, value)
            value, _ = await load_settings(session)
            self.assertEqual(value.api_key, "private-key")
            value.api_key = ""
            await save_settings(session, value)
            value, _ = await load_settings(session)
            self.assertFalse(value.api_key)

    async def test_disabled_does_not_call_model(self):
        with patch.object(ModelClient, "request", new_callable=AsyncMock) as mocked:
            for path in ("/test", "/jobs"):
                response = await self.client.post(
                    "/api/agent" + path,
                    json={"kind": "game"} if path == "/jobs" else None,
                    headers=self.headers,
                )
                self.assertEqual(response.status_code, 409)
            response = await self.client.get("/api/agent/models", headers=self.headers)
            self.assertEqual(response.status_code, 409)
            mocked.assert_not_awaited()

    async def test_backup_omits_agent_secrets_and_disables_restored_config(self):
        from cli.backup import build_payload, SCOPE_LIBRARY

        await self.configure(
            api_key="private-key", proxy_password="private-proxy-password"
        )
        payload = await build_payload(self.config, SCOPE_LIBRARY)
        settings = payload["settings"]["agent"]
        self.assertFalse(settings["enabled"])
        self.assertEqual(settings["api_key"], "")
        self.assertNotIn("private-key", json.dumps(payload))
        self.assertNotIn("private-proxy-password", json.dumps(payload))

    async def test_proxy_modes(self):
        self.config.proxy = "http://inherited.invalid"
        self.assertIsNone(client_options(AgentSettings())["proxy"])
        self.assertFalse(client_options(AgentSettings())["trust_env"])
        self.assertEqual(
            client_options(AgentSettings(proxy_mode="inherit"))["proxy"],
            self.config.proxy,
        )
        options = client_options(
            AgentSettings(
                proxy_mode="custom",
                proxy_url="socks5://proxy.invalid:1080",
                proxy_username="a@b",
                proxy_password="a:b",
            )
        )
        self.assertEqual(options["proxy"], "socks5://a%40b:a%3Ab@proxy.invalid:1080")
        self.assertFalse(options["follow_redirects"])

    async def test_saved_keys_do_not_follow_a_new_endpoint(self):
        await self.configure(
            api_key="old-key",
            proxy_url="http://old.invalid",
            proxy_password="old-proxy",
        )
        async with self.sessions() as session:
            value, _ = await load_settings(session)
            value.base_url = "https://other.invalid/v1"
            value.proxy_url = "http://other.invalid"
            value.api_key = None
            value.proxy_password = None
            await save_settings(session, value)
            value, _ = await load_settings(session)
            self.assertFalse(value.api_key)
            self.assertFalse(value.proxy_password)

    async def test_cancel_and_disable_stop_next_call(self):
        await self.configure()
        async with self.sessions() as session:
            job = AgentJob(kind="game", request={}, actor_id=self.user_id)
            session.add(job)
            await session.commit()
            settings, revision = await load_settings(session)
            runtime = Runtime(session, job, settings, revision)
            await runtime.check(model=True)
            job.calls = settings.max_calls
            await session.commit()
            with self.assertRaises(AgentBudget):
                await runtime.check(model=True)
            job.calls = 0
            job.cancel_requested = True
            await session.commit()
            with self.assertRaises(AgentStopped):
                await runtime.check()

    async def test_settings_change_invalidates_model_context(self):
        await self.configure()
        async with self.sessions() as session:
            job = AgentJob(kind="game", request={})
            session.add(job)
            await session.commit()
            settings, rev = await load_settings(session)
            runtime = Runtime(session, job, settings, rev)
            settings = settings.model_copy(update={"model": "changed-model"})
            await save_settings(session, settings)
            with self.assertRaises(AgentBudget):
                await runtime.check(model=True)

    async def test_protocol_adapters_and_tool_results(self):
        tool = tool_spec("probe", "test", object_schema({"ok": {"type": "boolean"}}))
        for protocol in ["chat", "responses", "anthropic", "gemini", "ollama"]:
            with self.subTest(protocol=protocol):
                calls = []

                async def handler(method, path, payload=None):
                    calls.append((path, payload))
                    if protocol == "chat":
                        return {
                            "choices": [
                                {
                                    "message": {
                                        "tool_calls": [
                                            {
                                                "id": "call1",
                                                "function": {
                                                    "name": "probe",
                                                    "arguments": '{"ok":true}',
                                                },
                                            }
                                        ]
                                    }
                                }
                            ]
                        }
                    if protocol == "ollama":
                        return {
                            "message": {
                                "tool_calls": [
                                    {
                                        "function": {
                                            "name": "probe",
                                            "arguments": {"ok": True},
                                        }
                                    }
                                ]
                            }
                        }
                    if protocol == "responses":
                        return {
                            "output": [
                                {
                                    "type": "function_call",
                                    "call_id": "call1",
                                    "name": "probe",
                                    "arguments": '{"ok":true}',
                                }
                            ]
                        }
                    if protocol == "anthropic":
                        return {
                            "content": [
                                {
                                    "type": "tool_use",
                                    "id": "call1",
                                    "name": "probe",
                                    "input": {"ok": True},
                                }
                            ]
                        }
                    return {
                        "candidates": [
                            {
                                "content": {
                                    "parts": [
                                        {
                                            "functionCall": {
                                                "name": "probe",
                                                "args": {"ok": True},
                                            }
                                        }
                                    ]
                                }
                            }
                        ]
                    }

                client = ModelClient(AgentSettings(protocol=protocol, model="test"))
                with patch.object(client, "request", side_effect=handler):
                    messages = [
                        {"role": "system", "content": "test"},
                        {"role": "user", "content": "probe"},
                    ]
                    result, _ = await client.turn(messages, [tool])
                    self.assertTrue(result["calls"][0]["arguments"]["ok"])
                    messages += [
                        result,
                        {
                            "role": "tool",
                            "tool_call_id": result["calls"][0]["id"],
                            "name": "probe",
                            "content": '{"ok":true}',
                        },
                    ]
                    await client.turn(messages, [tool])
                    self.assertEqual(len(calls), 2)

    async def test_model_redirects_and_errors_do_not_leak_keys(self):
        real = httpx.AsyncClient
        for code in [302, 401, 500]:
            transport = httpx.MockTransport(
                lambda r: httpx.Response(
                    code,
                    headers={"Location": "https://other.invalid"},
                    json={"key": "private-key"},
                )
            )
            with patch(
                "services.agent.providers.httpx.AsyncClient",
                side_effect=lambda **kw: real(transport=transport, **kw),
            ):
                with self.assertRaises(ModelError) as caught:
                    await ModelClient(
                        AgentSettings(api_key="private-key", model="test")
                    ).models()
                self.assertNotIn("private-key", str(caught.exception))

    async def test_safe_inventory_and_archive_instructions(self):
        root = Path(self.tmp.name) / "games"
        root.mkdir()
        nested = root / "arbitrary" / "nested"
        nested.mkdir(parents=True)
        archive = nested / "test.zip"
        with zipfile.ZipFile(archive, "w") as z:
            z.writestr("README.txt", "Copy files into game root directory.")
            z.writestr("Data/a.pak", "test")
        (root / "outside").symlink_to(Path(self.tmp.name), target_is_directory=True)
        model = RootDirectory(
            id=1, path=str(root), source_type="local", source_path=str(root)
        )
        files = inventory(model, None, set())
        self.assertEqual(len(files), 1)
        self.assertEqual(files[0]["relative"], "arbitrary/nested/test.zip")
        evidence = archive_evidence(archive)
        self.assertEqual(
            evidence["documents"][0]["text"], "Copy files into game root directory."
        )
        for p in ("../x", "/tmp/x", "C:/x", "a/../b", "a\x00b"):
            with self.assertRaises(ValueError):
                relative_path(p)

    async def make_game_job(self):
        root = Path(self.tmp.name) / "games"
        root.mkdir()
        (root / "strange").mkdir()
        with zipfile.ZipFile(root / "strange" / "Test Game.zip", "w") as z:
            z.writestr("Data/test", "test")
        async with self.sessions() as session:
            r = RootDirectory(
                path=str(root), source_path=str(root), source_type="local"
            )
            session.add(r)
            await session.flush()
            job = AgentJob(
                kind="game", actor_id=self.user_id, request={"root_ids": [r.id]}
            )
            session.add(job)
            await session.commit()
            return job.id

    async def test_game_scan_runs_agent_before_fallback_and_deduplicates(self):
        await self.configure()
        job_id = await self.make_game_job()

        async def turn(messages, tools):
            discovery = "Identify game boundaries" in messages[0]["content"]
            if not any(m["role"] == "tool" for m in messages):
                return {
                    "role": "assistant",
                    "content": "",
                    "calls": [
                        {
                            "id": "q",
                            "name": "search",
                            "arguments": {"query": "Test Game"},
                        }
                    ],
                }, 10
            args = (
                {
                    "groups": [
                        {"candidate": 0, "files": [0], "evidence": "Test Game.zip"}
                    ]
                }
                if discovery
                else {
                    "candidate": 0,
                    "evidence": "Matching filename and verified Steam result",
                }
            )
            return {
                "role": "assistant",
                "content": "",
                "calls": [{"id": "done", "name": "submit", "arguments": args}],
            }, 10

        with (
            patch.object(ModelClient, "turn", side_effect=turn),
            patch(
                "services.agent.metadata._build_scrapers", return_value=[FakeScraper()]
            ),
        ):
            await run_job(job_id)
        async with self.sessions() as session:
            job = await session.get(AgentJob, job_id)
            self.assertEqual(job.status, "completed", job.message)
            games = (await session.execute(select(Game))).scalars().all()
            self.assertEqual(len(games), 1)
            self.assertEqual(games[0].steam_id, "123")
            self.assertEqual(
                len((await session.execute(select(GameVersion))).scalars().all()), 1
            )
            self.assertGreater(job.calls, 0)

    async def test_model_failure_falls_back_to_regular_scan(self):
        await self.configure()
        job_id = await self.make_game_job()
        with (
            patch.object(ModelClient, "turn", side_effect=ModelError("unavailable")),
            patch(
                "services.agent.metadata._build_scrapers", return_value=[FakeScraper()]
            ),
        ):
            await run_job(job_id)
        async with self.sessions() as session:
            job = await session.get(AgentJob, job_id)
            self.assertEqual(job.status, "completed", job.message)
            self.assertEqual(
                len((await session.execute(select(Game))).scalars().all()), 1
            )
            statuses = (
                (await session.execute(select(AgentResult.status))).scalars().all()
            )
            self.assertIn("fallback", statuses)

    async def test_job_single_flight_and_recovery(self):
        await self.configure()
        with patch("api.agent.launch"):
            first = await self.client.post(
                "/api/agent/jobs", json={"kind": "game"}, headers=self.headers
            )
            self.assertEqual(first.status_code, 200)
            second = await self.client.post(
                "/api/agent/jobs", json={"kind": "patch"}, headers=self.headers
            )
            self.assertEqual(second.status_code, 409)
            await agent.interrupt_jobs()
            detail = await self.client.get(
                "/api/agent/jobs/" + str(first.json()["id"]), headers=self.headers
            )
            self.assertEqual(detail.json()["status"], "interrupted")

    async def test_patch_matching_manifest_and_steam_name(self):
        await self.configure()
        root = Path(self.tmp.name) / "patches"
        root.mkdir()
        instructions = "Copy the contents of payload into the game root directory."
        with zipfile.ZipFile(root / "Test Game Patch.zip", "w") as z:
            z.writestr("README.txt", instructions)
            z.writestr("payload/Data/translation.pak", "test")
        async with self.sessions() as session:
            session.add(
                SteamPatchRoot(
                    path=str(root), source_type="local", analysis_mode="auto"
                )
            )
            job = AgentJob(kind="patch", actor_id=self.user_id, request={})
            session.add(job)
            await session.commit()
            job_id = job.id

        async def turn(messages, tools):
            outputs = [m.get("name") for m in messages if m["role"] == "tool"]
            if "inspect_patch" not in outputs:
                name, args = "inspect_patch", {}
            elif "search" not in outputs:
                name, args = "search", {"query": "Test Game"}
            else:
                name, args = (
                    "submit",
                    {
                        "candidate": 0,
                        "patch_dir": "payload",
                        "target_dir": "",
                        "copy_only": True,
                        "instruction_quote": instructions,
                        "evidence": instructions,
                    },
                )
            return {
                "role": "assistant",
                "content": "",
                "calls": [{"id": str(len(messages)), "name": name, "arguments": args}],
            }, 10

        with (
            patch.object(ModelClient, "turn", side_effect=turn),
            patch(
                "services.agent.metadata._build_scrapers", return_value=[FakeScraper()]
            ),
            patch("scan_patches._steam_name_for_app_id", return_value="Steam中文名称"),
        ):
            await run_job(job_id)
        async with self.sessions() as session:
            job = await session.get(AgentJob, job_id)
            self.assertEqual(job.status, "completed", job.message)
        data = json.loads(
            (Path(self.tmp.name) / "steam_patch_index" / "patches.json").read_text()
        )["patches"][0]
        self.assertEqual(data["game_name"], "Steam中文名称")
        self.assertEqual(data["patch_dir"], "payload")
        self.assertEqual(data["target_dir"], "")
        self.assertEqual(data["manifest_status"], "confirmed")

    async def test_job_results_survive_cancel_and_ownership_change(self):
        await self.configure()
        async with self.sessions() as session:
            job = AgentJob(kind="game", request={}, actor_id=self.user_id)
            session.add(job)
            await session.commit()
            settings, rev = await load_settings(session)
            runtime = Runtime(session, job, settings, rev)
            user = await session.get(User, self.user_id)
            user.role = "user"
            await session.commit()
            with self.assertRaises(AgentStopped):
                await runtime.check()

    async def test_zip_symlink_and_oversized_instructions_rejected(self):
        archive = Path(self.tmp.name) / "unsafe.zip"
        with zipfile.ZipFile(archive, "w") as z:
            entry = zipfile.ZipInfo("link")
            entry.external_attr = 0o120777 << 16
            z.writestr(entry, "/etc/passwd")
        with self.assertRaises(ValueError):
            archive_evidence(archive)

    async def test_tool_budget_is_shared_across_items(self):
        await self.configure(max_calls=1)
        async with self.sessions() as session:
            job = AgentJob(kind="game", request={})
            session.add(job)
            await session.commit()
            settings, rev = await load_settings(session)
            runtime = Runtime(session, job, settings, rev)
            reply = {
                "role": "assistant",
                "content": "",
                "calls": [{"id": "done", "name": "submit", "arguments": {"ok": True}}],
            }
            with patch.object(ModelClient, "turn", return_value=(reply, 10)) as mocked:
                result = await runtime.reason(
                    "metadata", {}, object_schema({"ok": {"type": "boolean"}})
                )
                self.assertTrue(result["ok"])
                with self.assertRaises(AgentBudget):
                    await runtime.reason("metadata", {}, object_schema({}))
                self.assertEqual(mocked.await_count, 1)
