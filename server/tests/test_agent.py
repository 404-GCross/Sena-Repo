import asyncio
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
from api import agent, auth, roots
from database import Base, get_session
from models.agent import AgentConfig, AgentJob, AgentResult
from models.game import Game, GameVersion
from models.root_directory import RootDirectory
from models.file_source import SteamPatchRoot
from models.user import User
from models.scrape_job import JobStatus, ScrapeJob
from utils.process_lock import process_lock, scan_lock_path
from schemas.agent import AgentSettings
from services.agent.inventory import (
    archive_evidence,
    inventory,
    relative_path,
    InventoryStopped,
)
from services.agent.jobs import run_job, collect_inventory
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
        self.assertEqual(data["max_calls"], 0)
        self.assertEqual(data["max_tokens"], 0)
        self.assertTrue(data["patch_steam_name"])
        self.assertTrue(data["game_ask"])
        self.assertEqual(data["background_preference"], "artwork")
        async with self.sessions() as session:
            user = await session.get(User, self.user_id)
            user.role = "user"
            await session.commit()
        for method, path, body in [
            ("GET", "/settings", None),
            ("PUT", "/settings", {"background_preference": "screenshot"}),
            ("POST", "/test", None),
            ("GET", "/models", None),
            ("GET", "/jobs", None),
            ("POST", "/jobs", {"kind": "game"}),
        ]:
            response = await self.client.request(
                method, "/api/agent" + path, json=body, headers=self.headers
            )
            self.assertEqual(response.status_code, 403)

    async def test_background_preference_survives_an_older_settings_client(self):
        url = '/api/agent/settings'
        saved = await self.client.put(url, headers=self.headers, json={'background_preference': 'screenshot'})
        self.assertEqual(saved.json()['background_preference'], 'screenshot')
        self.assertFalse(saved.json()['vision'])
        legacy = await self.client.put(url, headers=self.headers, json={'cover_language': 'source'})
        self.assertEqual(legacy.json()['background_preference'], 'screenshot')
        invalid = await self.client.put(url, headers=self.headers, json={'background_preference': 'other'})
        self.assertEqual(invalid.status_code, 422)

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
        await self.configure(max_calls=2)
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
                    self.assertIn("cGl4ZWxz", json.dumps(payload))
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
                        {"role": "user", "content": "probe", "images": ["data:image/png;base64,cGl4ZWxz"]},
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

    async def test_inventory_progress_is_saved_before_model_calls(self):
        await self.configure()
        async with self.sessions() as session:
            job = AgentJob(kind="game", request={}, actor_id=self.user_id)
            session.add(job)
            await session.commit()
            settings, revision = await load_settings(session)
            runtime = Runtime(session, job, settings, revision)
            root = RootDirectory(path="/example", source_type="openlist")

            def fake_inventory(root, source, ignored, *, on_progress, stop_requested):
                self.assertFalse(stop_requested())
                on_progress(3, 20, 8)
                return []

            with (
                patch("services.agent.jobs.inventory", side_effect=fake_inventory),
                patch.object(ModelClient, "turn", new_callable=AsyncMock) as model,
            ):
                self.assertEqual(
                    await collect_inventory(runtime, root, None, set()), []
                )
                model.assert_not_awaited()
            await session.refresh(job)
            self.assertEqual(job.calls, 0)
            self.assertIn("OpenList", job.message)
            self.assertIn("3 个目录", job.message)
            self.assertIn("20 个条目", job.message)
            self.assertIn("8 个候选文件", job.message)

    async def test_cancelled_inventory_does_not_request_another_directory(self):
        root = RootDirectory(path=self.tmp.name, source_type="local")
        with patch("services.agent.inventory.adapter_from_source") as adapter:
            with self.assertRaises(InventoryStopped):
                inventory(root, None, set(), stop_requested=lambda: True)
            adapter.return_value.list.assert_not_called()

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
            self.assertIn("model_fallback", statuses)

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

    async def test_zero_budgets_do_not_limit_a_task(self):
        await self.configure()
        async with self.sessions() as session:
            job = AgentJob(kind="game", request={}, calls=5000, tokens=3000000)
            session.add(job)
            await session.commit()
            settings, revision = await load_settings(session)
            await Runtime(session, job, settings, revision).check(model=True)

    async def seed_clear_records(self):
        folder = Path(self.tmp.name) / "clear-library"
        folder.mkdir()
        ids = {}
        async with self.sessions() as session:
            root = RootDirectory(
                path=str(folder), source_path=str(folder), source_type="local"
            )
            session.add(root)
            await session.flush()
            for name, values in {
                "scanned": {},
                "manual": {"entry_source": "manual"},
                "name_locked": {"name_locked": True},
                "metadata_locked": {"metadata_locked": True},
            }.items():
                path = folder / (name + ".zip")
                path.write_bytes(b"fixture")
                game = Game(name=name, root_id=root.id, folder_path=str(path), **values)
                session.add(game)
                await session.flush()
                ids[name] = game.id
                session.add(
                    GameVersion(
                        game_id=game.id,
                        platform="PC",
                        filename=path.name,
                        file_path=str(path),
                    )
                )
            await session.commit()
            return root.id, ids, folder

    async def test_agent_clear_preserves_protected_rows_and_retry_does_not_clear_twice(
        self,
    ):
        await self.configure()
        root_id, ids, folder = await self.seed_clear_records()
        with patch("api.agent.launch"):
            response = await self.client.post(
                "/api/agent/jobs",
                headers=self.headers,
                json={
                    "kind": "game",
                    "root_ids": [root_id],
                    "clear_existing": True,
                },
            )
        self.assertEqual(response.status_code, 200, response.text)
        job_id = response.json()["id"]
        with (
            patch("services.agent.jobs.discover_root", new_callable=AsyncMock),
            patch("services.agent.jobs.scrape_game", new_callable=AsyncMock),
        ):
            await run_job(job_id)
        async with self.sessions() as session:
            job = await session.get(AgentJob, job_id)
            self.assertEqual(job.status, "completed", job.message)
            self.assertFalse(job.request["clear_existing"])
            self.assertTrue(job.request["retry"])
            self.assertIsNone(await session.get(Game, ids["scanned"]))
            for key in ("manual", "name_locked", "metadata_locked"):
                self.assertIsNotNone(await session.get(Game, ids[key]))
            self.assertEqual(
                len((await session.execute(select(GameVersion))).scalars().all()), 3
            )
            unlocked = await session.get(Game, ids["name_locked"])
            unlocked.name_locked = False
            await session.commit()
        self.assertTrue((folder / "scanned.zip").is_file())
        with patch("api.agent.launch"):
            retry = await self.client.post(
                f"/api/agent/jobs/{job_id}/retry", headers=self.headers
            )
        self.assertEqual(retry.status_code, 200, retry.text)
        with (
            patch("services.agent.jobs.discover_root", new_callable=AsyncMock),
            patch("services.agent.jobs.scrape_game", new_callable=AsyncMock),
        ):
            await run_job(retry.json()["id"])
        async with self.sessions() as session:
            self.assertIsNotNone(await session.get(Game, ids["name_locked"]))

    async def test_clear_cancelled_or_unconfigured_before_start_keeps_all_records(self):
        root_id, ids, _ = await self.seed_clear_records()
        for case in ("cancelled", "disabled", "missing_model"):
            await self.configure()
            async with self.sessions() as session:
                if case != "cancelled":
                    settings, _ = await load_settings(session)
                    if case == "disabled":
                        settings.enabled = False
                    else:
                        settings.model = ""
                    await save_settings(session, settings)
                job = AgentJob(
                    kind="game",
                    actor_id=self.user_id,
                    cancel_requested=case == "cancelled",
                    request={
                        "kind": "game",
                        "root_ids": [root_id],
                        "clear_existing": True,
                    },
                )
                session.add(job)
                await session.commit()
                job_id = job.id
            await run_job(job_id)
            async with self.sessions() as session:
                self.assertEqual(
                    (await session.get(AgentJob, job_id)).status,
                    "failed" if case == "missing_model" else "cancelled",
                )
                self.assertEqual(
                    set((await session.execute(select(Game.id))).scalars()),
                    set(ids.values()),
                )

    async def test_clear_rejects_wrong_scope_and_running_scrape(self):
        await self.configure()
        root_id, ids, _ = await self.seed_clear_records()
        response = await self.client.post(
            "/api/agent/jobs",
            headers=self.headers,
            json={"kind": "patch", "clear_existing": True},
        )
        self.assertEqual(response.status_code, 422)
        async with self.sessions() as session:
            session.add(ScrapeJob(status=JobStatus.RUNNING))
            await session.commit()
        response = await self.client.post(
            "/api/agent/jobs",
            headers=self.headers,
            json={"kind": "game", "root_ids": [root_id], "clear_existing": True},
        )
        self.assertEqual(response.status_code, 409)
        async with self.sessions() as session:
            self.assertEqual(
                set((await session.execute(select(Game.id))).scalars()),
                set(ids.values()),
            )

    async def test_clear_does_not_delete_when_scan_lock_is_busy(self):
        await self.configure()
        root_id, ids, _ = await self.seed_clear_records()
        async with self.sessions() as session:
            job = AgentJob(
                kind="game",
                request={"kind": "game", "root_ids": [root_id], "clear_existing": True},
            )
            session.add(job)
            await session.commit()
            job_id = job.id
        with process_lock(scan_lock_path(self.tmp.name), blocking=False) as acquired:
            self.assertTrue(acquired)
            await run_job(job_id)
        async with self.sessions() as session:
            self.assertEqual((await session.get(AgentJob, job_id)).status, "failed")
            self.assertEqual(
                set((await session.execute(select(Game.id))).scalars()),
                set(ids.values()),
            )

    async def test_regular_clear_rejects_pending_agent_task(self):
        _, ids, _ = await self.seed_clear_records()
        self.app.include_router(roots.router)
        async with self.sessions() as session:
            session.add(AgentJob(kind="game", request={}, status="pending"))
            await session.commit()
        with patch("api.roots._bg_scan") as launch:
            response = await self.client.post(
                "/api/roots/clear-and-refresh", headers=self.headers
            )
            self.assertEqual(response.status_code, 409, response.text)
            launch.assert_not_called()
        async with self.sessions() as session:
            self.assertEqual(
                set((await session.execute(select(Game.id))).scalars()),
                set(ids.values()),
            )

    async def test_skipped_regular_scan_does_not_remain_pending(self):
        with (
            patch.dict(roots._scan_state, {"status": "pending"}),
            patch.object(roots, "_background_tasks", set()),
            patch.object(
                roots,
                "_run_scan",
                new_callable=AsyncMock,
                return_value={"skipped": True},
            ),
        ):
            roots._bg_scan(self.config, [])
            await next(iter(roots._background_tasks))
            self.assertEqual(roots._scan_state["status"], "failed")
            self.assertIn("未启动", roots._scan_state["message"])

    async def test_pending_agent_stop_is_idempotent_and_never_starts_model(self):
        async with self.sessions() as s:
            row = AgentJob(kind="game", request={}, status="pending")
            s.add(row)
            await s.commit()
            key = row.id
        for _ in range(2):
            r = await self.client.post(
                f"/api/agent/jobs/{key}/cancel", headers=self.headers
            )
            self.assertEqual(r.json()["status"], "cancelled")
        with patch.object(ModelClient, "turn", new_callable=AsyncMock) as model:
            self.assertEqual(await run_job(key), "cancelled")
            model.assert_not_awaited()

    async def test_nonadmins_cannot_stop_any_task_type(self):
        from api import scraper, steam_patch

        self.app.include_router(roots.router)
        self.app.include_router(scraper.router)
        self.app.include_router(steam_patch.router)
        async with self.sessions() as s:
            user = User(
                username="viewer",
                role="user",
                status="active",
                password_hash="unused",
                salt="unused",
            )
            s.add(user)
            await s.flush()
            token = await auth._issue_session_token(user, s)
            await s.commit()
        for path in [
            "/api/agent/jobs/1/cancel",
            "/api/scrape/jobs/1/cancel",
            "/api/roots/scan-status/old/stop",
            "/api/steam/scan-patches/old/stop",
        ]:
            with self.subTest(path=path):
                r = await self.client.post(
                    path, headers={"Authorization": "Bearer " + token}
                )
                self.assertEqual(r.status_code, 403, r.text)

    async def test_stopped_scan_cannot_start_follow_up_scrape(self):
        from api import scraper

        self.app.include_router(scraper.router)
        for status, key in [("cancelled", "same"), ("completed", "different")]:
            with (
                self.subTest(status=status),
                patch.dict(roots._scan_state, {"status": status, "run_id": key}),
            ):
                r = await self.client.post(
                    "/api/scrape/batch",
                    headers=self.headers,
                    json={"after_scan_id": "same"},
                )
                self.assertEqual(r.status_code, 409, r.text)
        async with self.sessions() as s:
            self.assertIsNone(await s.scalar(select(ScrapeJob.id).limit(1)))

    async def test_stopping_root_mid_enumeration_preserves_unseen_records(self):
        import threading
        from services.scanner import ScanResult
        from services.task_stop import checkpoint

        self.app.include_router(roots.router)
        async with self.sessions() as s:
            root = RootDirectory(path=self.tmp.name)
            s.add(root)
            await s.flush()
            game = Game(
                name="Keep", root_id=root.id, folder_path=self.tmp.name + "/unseen"
            )
            s.add(game)
            await s.commit()
            game_id = game.id
        entered, release = threading.Event(), threading.Event()

        def scan(*args):
            entered.set()
            release.wait(4)
            checkpoint()
            return ScanResult(self.tmp.name)

        with (
            patch.dict(roots._scan_state, {"status": "idle"}),
            patch("services.importer.scan_root", side_effect=scan),
        ):
            run = asyncio.create_task(roots._run_scan(self.config))
            try:
                self.assertTrue(await asyncio.to_thread(entered.wait, 3))
                key = roots._scan_state["run_id"]
                url = "/api/roots/scan-status/"
                self.assertEqual(
                    (
                        await self.client.post(url + "stale/stop", headers=self.headers)
                    ).status_code,
                    409,
                )
                self.assertEqual(
                    (
                        await self.client.post(
                            url + key + "/stop", headers=self.headers
                        )
                    ).json()["status"],
                    "stopping",
                )
            finally:
                release.set()
                result = await run
            self.assertEqual(result["status"], "cancelled")
            self.assertEqual(roots._scan_state["roots_completed"], 0)
            async with self.sessions() as s:
                self.assertFalse((await s.get(Game, game_id)).is_deleted)

    async def test_stop_patch_reset_never_publishes_partial_index(self):
        import threading
        from api import steam_patch

        self.app.include_router(steam_patch.router)
        entered, release = threading.Event(), threading.Event()

        def scan(*args):
            entered.set()
            release.wait(4)
            return []

        index = steam_patch._get_patch_index_dir(self.config)
        index.mkdir(parents=True, exist_ok=True)
        path = index / "patches.json"
        path.write_text('{"patches":[{"file":"keep.zip","locked":true}]}')
        old = path.read_bytes()
        with (
            patch.dict(steam_patch._patch_scan_state, {"status": "idle"}),
            patch("scan_patches.scan_patches_dir", side_effect=scan),
        ):
            task = asyncio.create_task(
                self.client.post(
                    "/api/steam/scan-patches?mode=reset", headers=self.headers
                )
            )
            try:
                self.assertTrue(await asyncio.to_thread(entered.wait, 3))
                key = steam_patch._patch_scan_state["run_id"]
                r = await self.client.post(
                    f"/api/steam/scan-patches/{key}/stop", headers=self.headers
                )
                self.assertEqual(r.json()["status"], "stopping")
            finally:
                release.set()
                response = await task
            self.assertEqual(response.json()["status"], "cancelled")
            self.assertEqual(path.read_bytes(), old)

    async def test_running_scrape_cancels_inflight_search_and_does_not_start_next_game(
        self,
    ):
        from api import scraper
        from services.scraper.orchestrator import run_batch_scrape

        self.app.include_router(scraper.router)
        entered = asyncio.Event()

        async def search(*args, **kwargs):
            entered.set()
            await asyncio.Event().wait()

        async with self.sessions() as s:
            root = RootDirectory(path=self.tmp.name)
            s.add(root)
            await s.flush()
            s.add_all(
                [
                    Game(name=n, root_id=root.id, folder_path=self.tmp.name + "/" + n)
                    for n in ("First", "Second")
                ]
            )
            job = ScrapeJob(status=JobStatus.PENDING)
            s.add(job)
            await s.commit()
            key = job.id
        with (
            patch(
                "services.scraper.orchestrator._build_scrapers",
                return_value=[FakeScraper()],
            ),
            patch.object(FakeScraper, "search_best", side_effect=search) as model,
        ):
            async with self.sessions() as worker:
                task = asyncio.create_task(
                    run_batch_scrape(self.config, None, worker, job)
                )
                try:
                    await asyncio.wait_for(entered.wait(), 3)
                    r = await self.client.post(
                        f"/api/scrape/jobs/{key}/cancel", headers=self.headers
                    )
                    self.assertIn(r.json()["status"], ("stopping", "cancelled"))
                    await asyncio.wait_for(task, 3)
                finally:
                    if not task.done():
                        task.cancel()
                        await asyncio.gather(task, return_exceptions=True)
                model.assert_awaited_once()
        r = await self.client.get(f"/api/scrape/jobs/{key}", headers=self.headers)
        self.assertEqual(r.json()["status"], "cancelled")
        self.assertEqual(r.json()["failed_games"], 0)

    async def test_explicit_budget_fallback_is_not_reported_as_model_failure(self):
        await self.configure(max_calls=1)
        job_id = await self.make_game_job()
        reply = {
            "role": "assistant",
            "content": "",
            "calls": [
                {"id": "query", "name": "search", "arguments": {"query": "Test Game"}}
            ],
        }
        with (
            patch.object(ModelClient, "turn", return_value=(reply, 10)) as model,
            patch(
                "services.agent.metadata._build_scrapers", return_value=[FakeScraper()]
            ),
        ):
            await run_job(job_id)
            self.assertEqual(model.await_count, 1)
        async with self.sessions() as session:
            job = await session.get(AgentJob, job_id)
            self.assertEqual(job.status, "completed")
            rows = (
                (
                    await session.execute(
                        select(AgentResult).where(AgentResult.job_id == job_id)
                    )
                )
                .scalars()
                .all()
            )
            self.assertTrue(any(row.status == "budget_fallback" for row in rows))
            self.assertFalse(any(row.status == "model_fallback" for row in rows))
            self.assertTrue(any("不代表无法识别" in row.summary for row in rows))
