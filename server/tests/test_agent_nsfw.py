import base64
import io
import json
import tempfile
import unittest
from datetime import datetime, timedelta
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch

import httpx
from PIL import Image
from pydantic import ValidationError
from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

import config
import database
from api import games
from cli import backup
from models.agent import AgentJob, AgentResult
from models.game import Game
from models.root_directory import RootDirectory
from models.user import User
from schemas.agent import AgentSettings
from services.agent.jobs import check_game_nsfw, scrape_game
from services.agent.nsfw import inspect_game_images
from services.agent.providers import ModelClient, ModelError
from services.agent.runtime import AgentStopped, Runtime
from services.agent.settings import load_settings, save_settings
from services.scraper.base import ScraperResult
from services.scraper.orchestrator import _apply_result, _reuse_existing_metadata


def response(*values):
    return {
        "role": "assistant",
        "content": "",
        "calls": [
            {
                "id": "classify",
                "name": "submit",
                "arguments": {
                    "images": [
                        {
                            "image": index,
                            "nudity": value,
                            "reason": "明确检出裸露" if value else "未检出或无法确定",
                        }
                        for index, value in enumerate(values)
                    ]
                },
            }
        ],
    }, 100


class AgentNsfwTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.config = config.Config(data_path=self.temp.name)
        self.engine = create_async_engine(self.config.database_url)
        self.sessions = async_sessionmaker(self.engine, expire_on_commit=False)
        for target, name, value in [
            (database, "_engine", self.engine),
            (config, "_cached_config", self.config),
        ]:
            item = patch.object(target, name, value)
            item.start()
            self.addCleanup(item.stop)
        await database.create_tables()
        self.session = self.sessions()
        self.settings = AgentSettings(
            enabled=True, vision=True, image_nsfw=True, model="vision-test"
        )
        revision = await save_settings(self.session, self.settings)
        root = RootDirectory(path=self.temp.name)
        self.session.add(root)
        await self.session.flush()
        self.cover = self.config.covers_path / "current.png"
        self.background = self.config.backgrounds_path / "current.png"
        Image.new("RGB", (64, 64), "red").save(self.cover)
        Image.new("RGB", (64, 64), "blue").save(self.background)
        self.game = Game(
            name="Name must not determine image content",
            root_id=root.id,
            folder_path=str(Path(self.temp.name) / "game"),
            description="Description",
            developer="Studio",
            cover_path=str(self.cover),
            bg_path=str(self.background),
        )
        self.job = AgentJob(kind="game", request={})
        self.session.add_all([self.game, self.job])
        await self.session.commit()
        self.runtime = Runtime(self.session, self.job, self.settings, revision)
        self.client = httpx.AsyncClient(
            transport=httpx.MockTransport(lambda _: httpx.Response(404))
        )
        self.user = User(id=1, role="admin", status="active")

    async def asyncTearDown(self):
        await self.client.aclose()
        await self.session.close()
        await self.engine.dispose()

    async def check(self):
        await check_game_nsfw(self.runtime, self.game, self.client, self.config)
        return (
            await self.session.execute(
                select(AgentResult).order_by(AgentResult.id.desc()).limit(1)
            )
        ).scalar_one()

    async def test_feature_defaults_off_and_requires_vision(self):
        self.assertFalse(AgentSettings().image_nsfw)
        self.assertFalse(AgentSettings().image_nsfw_recheck)
        with self.assertRaises(ValidationError):
            AgentSettings(image_nsfw=True)
        self.runtime.settings = AgentSettings()
        with patch.object(ModelClient, "turn", new_callable=AsyncMock) as model:
            self.assertIsNone(
                await inspect_game_images(
                    self.runtime, self.game, self.client, self.config
                )
            )
            model.assert_not_awaited()

    async def test_only_enabled_library_scans_create_image_checks(self):
        self.settings.image_nsfw_recheck = True
        self.game.bg_path = "https://public.example/changed-background.png"
        for kind, ids, enabled, checked in [
            ("game", [], False, False),
            ("scrape", [self.game.id], True, False),
            ("scrape", [self.game.id, self.game.id + 1], True, True),
            ("patch", [], True, False),
        ]:
            with self.subTest(kind=kind, ids=ids):
                self.job.kind, self.job.request = kind, {"game_ids": ids}
                self.settings.image_nsfw = enabled
                self.game.nsfw_image_checked = checked
                await self.session.commit()
                with (
                    patch("services.agent.nsfw._local_bytes") as local,
                    patch("services.agent.nsfw._remote_bytes", new_callable=AsyncMock) as remote,
                    patch.object(ModelClient, "turn", new_callable=AsyncMock) as model,
                ):
                    await check_game_nsfw(self.runtime, self.game, self.client, self.config)
                    local.assert_not_called()
                    remote.assert_not_awaited()
                    model.assert_not_awaited()
                self.assertIsNone((await self.session.scalars(select(AgentResult.id))).first())
                await self.session.refresh(self.game)
                self.assertEqual(self.game.nsfw_image_checked, checked)
                self.assertFalse(self.game.is_nsfw)

    async def test_actual_background_detection_enables_nsfw_and_records_evidence(self):
        with patch.object(
            ModelClient,
            "turn",
            new_callable=AsyncMock,
            return_value=response(False, True),
        ) as model:
            result = await self.check()
        self.assertEqual(result.status, "nsfw_enabled")
        await self.session.refresh(self.game)
        self.assertTrue(self.game.is_nsfw)
        self.assertFalse(self.game.nsfw_manual)
        messages = model.await_args.args[0]
        context = json.loads(messages[1]["content"])
        self.assertEqual(
            context["images"],
            [{"image": 0, "kind": "封面"}, {"image": 1, "kind": "背景"}],
        )
        self.assertNotIn(self.game.name, messages[1]["content"])
        images = messages[1]["images"]
        self.assertEqual(len(images), 2)
        with Image.open(
            io.BytesIO(base64.b64decode(images[1].split(",", 1)[1]))
        ) as image:
            self.assertGreater(image.getpixel((0, 0))[2], 240)
        self.assertIn("背景", result.summary)
        self.assertNotIn("data:image", json.dumps(result.data))
        self.assertEqual(self.job.calls, 1)

    async def test_manual_off_locked_and_already_enabled_games_are_preserved(self):
        with patch.object(ModelClient, "turn", new_callable=AsyncMock) as model:
            for values in [
                (False, True, False),
                (False, False, True),
                (True, False, False),
            ]:
                self.game.is_nsfw, self.game.nsfw_manual, self.game.metadata_locked = (
                    values
                )
                await self.session.commit()
                result = await self.check()
                self.assertEqual(result.status, "nsfw_skipped")
                self.assertEqual(self.game.is_nsfw, values[0])
            model.assert_not_awaited()

    async def test_unknown_model_failure_and_invalid_indexes_do_not_change_the_flag(
        self,
    ):
        cases = [response(None, False), response(True, True), response(True, False)]
        cases[1][0]["calls"][0]["arguments"]["images"][1]["image"] = 0
        cases[2][0]["calls"][0]["arguments"]["images"][0]["nudity"] = "true"
        for payload in cases:
            with patch.object(
                ModelClient, "turn", new_callable=AsyncMock, return_value=payload
            ):
                self.assertEqual((await self.check()).status, "nsfw_unknown")
            self.assertFalse(self.game.is_nsfw)
        with patch.object(
            ModelClient, "turn", side_effect=ModelError("Image input unsupported")
        ):
            self.assertEqual((await self.check()).status, "nsfw_unknown")
        self.assertFalse(self.game.is_nsfw)

    async def test_budget_exhaustion_does_not_make_another_model_request(self):
        self.settings.max_calls = 1
        revision = await save_settings(self.session, self.settings)
        self.job.calls = 1
        await self.session.commit()
        self.runtime = Runtime(self.session, self.job, self.settings, revision)
        with patch.object(ModelClient, "turn", new_callable=AsyncMock) as model:
            self.assertEqual((await self.check()).status, "nsfw_unknown")
            model.assert_not_awaited()
        self.assertFalse(self.game.is_nsfw)

    async def test_cached_metadata_still_checks_changed_image_contents(self):
        self.settings.image_nsfw_recheck = True
        self.runtime.revision = await save_settings(self.session, self.settings)

        async def metadata(runtime, catalog, context):
            catalog.selection = SimpleNamespace(platforms={})
            return ScraperResult(
                title=self.game.name, source_name="steam"
            ), "Verified metadata"

        with (
            patch("services.agent.metadata._build_scrapers", return_value=[]),
            patch(
                "services.agent.jobs.select_metadata", side_effect=metadata
            ) as selector,
            patch("services.agent.jobs._apply_result", new_callable=AsyncMock),
            patch.object(
                ModelClient,
                "turn",
                side_effect=[response(False, False), response(False, True)],
            ) as model,
        ):
            await scrape_game(self.runtime, self.game, self.client)
            await scrape_game(self.runtime, self.game, self.client)
            self.assertEqual(model.await_count, 1)
            Image.new("RGB", (64, 64), "green").save(self.background)
            await scrape_game(self.runtime, self.game, self.client)
            self.assertEqual(model.await_count, 2)
            self.assertEqual(selector.await_count, 1)
        await self.session.refresh(self.game)
        self.assertTrue(self.game.is_nsfw)

    async def test_manual_off_during_model_call_wins(self):
        async def turn(*args):
            async with self.sessions() as other:
                await games.update_game(
                    self.game.id, games.GameUpdate(is_nsfw=False), self.user, other
                )
            return response(True, True)

        with patch.object(ModelClient, "turn", side_effect=turn):
            self.assertEqual((await self.check()).status, "nsfw_skipped")
        await self.session.refresh(self.game)
        self.assertFalse(self.game.is_nsfw)
        self.assertTrue(self.game.nsfw_manual)

    async def test_replacing_image_at_same_path_during_analysis_discards_result(self):
        async def turn(*args):
            Image.new("RGB", (64, 64), "white").save(self.cover)
            return response(True, False)

        with patch.object(ModelClient, "turn", side_effect=turn):
            self.assertEqual((await self.check()).status, "nsfw_skipped")
        self.assertFalse(self.game.is_nsfw)

    async def test_cancelled_or_disabled_detection_cannot_apply_late_result(self):
        async def turn(*args):
            settings, _ = await load_settings(self.session)
            settings.image_nsfw = False
            await save_settings(self.session, settings)
            return response(True, True)

        with patch.object(ModelClient, "turn", side_effect=turn):
            self.assertEqual((await self.check()).status, "nsfw_skipped")
        self.assertFalse(self.game.is_nsfw)
        self.job.cancel_requested = True
        await self.session.commit()
        with patch.object(ModelClient, "turn", new_callable=AsyncMock) as model:
            with self.assertRaises(AgentStopped):
                await self.check()
            model.assert_not_awaited()

    async def test_unreadable_images_do_not_send_files_outside_media_directories(self):
        outside = Path(self.temp.name) / "private.png"
        Image.new("RGB", (32, 32)).save(outside)
        self.cover.unlink()
        self.cover.symlink_to(outside)
        self.background.write_bytes(b"invalid image")
        with patch.object(ModelClient, "turn", new_callable=AsyncMock) as model:
            result = await self.check()
            self.assertEqual(result.status, "nsfw_unknown")
            model.assert_not_awaited()
        self.assertNotIn(str(outside), json.dumps(result.data))
        self.assertFalse(self.game.is_nsfw)

    async def test_remote_images_follow_ordinary_client_and_validate_redirects(self):
        self.game.cover_path = "https://public.example/cover"
        self.game.bg_path = None
        await self.session.commit()
        payload = self.cover.read_bytes()
        visited = []

        def transport(request):
            visited.append(str(request.url))
            if request.url.path == "/cover":
                return httpx.Response(302, headers={"Location": "/final"})
            return httpx.Response(200, content=payload)

        async with httpx.AsyncClient(
            transport=httpx.MockTransport(transport)
        ) as client:
            with (
                patch(
                    "services.agent.images._is_public_http_url",
                    new_callable=AsyncMock,
                    return_value=True,
                ) as validate,
                patch.object(
                    ModelClient,
                    "turn",
                    new_callable=AsyncMock,
                    return_value=response(True),
                ),
            ):
                result = await inspect_game_images(
                    self.runtime, self.game, client, self.config
                )
                self.assertEqual(result.status, "nsfw_enabled")
                self.assertEqual(validate.await_count, 2)
        self.assertEqual(
            visited, ["https://public.example/cover", "https://public.example/final"]
        )

    async def test_manual_policy_and_source_overwrite_only_enable_contract(self):
        await games.update_game(
            self.game.id,
            games.GameUpdate(description="Changed"),
            self.user,
            self.session,
        )
        self.assertFalse(self.game.nsfw_manual)
        await games.update_game(
            self.game.id, games.GameUpdate(is_nsfw=False), self.user, self.session
        )
        self.assertTrue(self.game.nsfw_manual)
        await _apply_result(
            ScraperResult(is_nsfw=True),
            "steam",
            self.game,
            self.client,
            self.config.covers_path,
            self.session,
            self.config,
            "overwrite",
        )
        await self.session.commit()
        await self.session.refresh(self.game)
        self.assertFalse(self.game.is_nsfw)
        self.game.nsfw_image_checked = True
        await self.session.commit()
        await games.update_game(
            self.game.id, games.GameUpdate(nsfw_manual=False), self.user, self.session
        )
        self.assertFalse(self.game.nsfw_image_checked)
        self.game.is_nsfw = True
        await self.session.commit()
        await _apply_result(
            ScraperResult(is_nsfw=False),
            "steam",
            self.game,
            self.client,
            self.config.covers_path,
            self.session,
            self.config,
            "overwrite",
            nsfw_enable_only=True,
        )
        await self.session.commit()
        await self.session.refresh(self.game)
        self.assertTrue(self.game.is_nsfw)

    async def test_legacy_migration_and_backup_preserve_flags_and_manual_policy(self):
        self.game.is_nsfw = True
        await self.session.commit()
        async with self.engine.begin() as conn:
            await conn.exec_driver_sql("ALTER TABLE games DROP COLUMN nsfw_manual")
        await database.create_tables()
        await self.session.refresh(self.game)
        self.assertTrue(self.game.is_nsfw)
        self.assertFalse(self.game.nsfw_manual)
        await games.update_game(
            self.game.id, games.GameUpdate(is_nsfw=False), self.user, self.session
        )
        library = await backup._export_library(self.session)
        self.assertTrue(library["games"][0]["nsfw_manual"])
        self.game.nsfw_image_checked = True
        await self.session.commit()
        library = await backup._export_library(self.session)
        self.assertTrue(library["games"][0]["nsfw_image_checked"])
        self.game.nsfw_manual = False
        self.game.nsfw_image_checked = False
        await self.session.commit()
        await backup.import_library(
            self.config,
            self.session,
            library,
            replace=False,
            source_map={},
            available_media={"covers": set(), "backgrounds": set()},
            overwrite_media=False,
        )
        await self.session.commit()
        await database.create_tables()
        await self.session.refresh(self.game)
        self.assertTrue(self.game.nsfw_manual)
        self.assertTrue(self.game.nsfw_image_checked)
        self.assertFalse(self.game.is_nsfw)

    async def test_image_changes_do_not_recheck_by_default_even_without_task_history(
        self,
    ):
        with patch.object(
            ModelClient, "turn", return_value=response(False, False)
        ) as model:
            self.assertEqual((await self.check()).status, "nsfw_checked")
            self.assertTrue(self.game.nsfw_image_checked)
            Image.new("RGB", (64, 64), "green").save(self.background)
            await self.session.execute(delete(AgentResult))
            await self.session.commit()
            with patch(
                "services.agent.nsfw._local_bytes",
                side_effect=AssertionError("Unexpected image read"),
            ):
                self.assertEqual((await self.check()).status, "nsfw_skipped")
            self.assertEqual(model.await_count, 1)
        self.assertFalse(self.game.is_nsfw)

    async def test_inconclusive_first_assessment_can_still_retry(self):
        with patch.object(
            ModelClient,
            "turn",
            side_effect=[response(None, False), response(False, True)],
        ) as model:
            self.assertEqual((await self.check()).status, "nsfw_unknown")
            self.assertFalse(self.game.nsfw_image_checked)
            Image.new("RGB", (64, 64), "green").save(self.background)
            self.assertEqual((await self.check()).status, "nsfw_enabled")
            self.assertEqual(model.await_count, 2)
        self.assertTrue(self.game.nsfw_image_checked)

    async def test_migration_remembers_completed_checks_without_matching_reused_ids(
        self,
    ):
        with patch.object(ModelClient, "turn", return_value=response(False, False)):
            await self.check()
        self.job.finished_at = datetime.utcnow()
        self.session.add(
            Game(
                id=999,
                name="New entry",
                root_id=self.game.root_id,
                folder_path=str(Path(self.temp.name) / "new-entry"),
                imported_at=self.job.finished_at + timedelta(seconds=1),
            )
        )
        self.session.add(
            AgentResult(
                job_id=self.job.id,
                key="999",
                fingerprint="",
                status="nsfw_checked",
                data={},
            )
        )
        await self.session.commit()
        async with self.engine.begin() as conn:
            await conn.exec_driver_sql(
                "ALTER TABLE games DROP COLUMN nsfw_image_checked"
            )
        await database.create_tables()
        await database.create_tables()
        await self.session.refresh(self.game)
        self.assertTrue(self.game.nsfw_image_checked)
        self.assertFalse((await self.session.get(Game, 999)).nsfw_image_checked)

    async def test_reused_metadata_respects_manual_nsfw_off(self):
        self.game.nsfw_manual = True
        self.session.add(
            Game(
                name=self.game.name,
                root_id=self.game.root_id,
                folder_path=str(Path(self.temp.name) / "other"),
                is_nsfw=True,
            )
        )
        await self.session.commit()
        await _reuse_existing_metadata(
            self.session, self.game, self.config.covers_path, self.config, "missing"
        )
        await self.session.commit()
        await self.session.refresh(self.game)
        self.assertFalse(self.game.is_nsfw)
