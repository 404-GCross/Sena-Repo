import io
import hashlib
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch

import httpx
from PIL import Image, ImageDraw
from sqlalchemy import select
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

import config
import database
from models.agent import AgentJob, AgentResult
from models.game import Game
from schemas.agent import AgentSettings
from services.agent.covers import CoverAsset, CoverChecker
from services.agent.images import image_preview
from services.agent.jobs import scrape_game
from services.agent.metadata import Catalog, select_metadata
from services.agent.providers import ModelError
from services.agent.runtime import AgentBudget, AgentStopped
from services.scraper.base import ScraperResult
from services.scraper.orchestrator import (
    _apply_result,
    _reuse_existing_metadata,
    scrape_single_game,
)


def image_bytes(width, height, *, stacked=False, compress_level=6):
    image = Image.new("RGB", (width, height), "blue")
    if stacked:
        ImageDraw.Draw(image).rectangle((0, 0, width, height // 2), fill="red")
    output = io.BytesIO()
    image.save(output, format="PNG", compress_level=compress_level)
    return output.getvalue()


def assessments(*rows):
    return {
        "covers": [
            {
                "cover": index,
                "layout": layout,
                "language": language,
                "identity": "match",
                "basis": "visible_title",
                "visible_title": "Original Game",
                "reason": "Two independent panels"
                if layout == "stacked"
                else "Complete single composition",
            }
            for index, layout, language in rows
        ]
    }


class AgentCoverTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.config = config.Config(data_path=self.temp.name)
        self.runtime = SimpleNamespace(
            settings=AgentSettings(vision=True),
            check=AsyncMock(),
            reason=AsyncMock(),
        )
        self.checker = CoverChecker(self.config, self.runtime)
        self.target = {
            "titles": ["Original Game"],
            "ambiguous_titles": [],
            "source_id": "1",
        }
        self.payloads = {}
        self.requests = []

        def transport(request):
            self.requests.append(str(request.url))
            return httpx.Response(
                200,
                content=self.payloads[str(request.url)],
                headers={"content-type": "application/octet-stream"},
            )

        self.client = httpx.AsyncClient(transport=httpx.MockTransport(transport))
        self.checker.client = self.client
        item = patch(
            "services.agent.images._is_public_http_url",
            new_callable=AsyncMock,
            return_value=True,
        )
        item.start()
        self.addCleanup(item.stop)

    async def asyncTearDown(self):
        await self.checker.close()

    def candidate(self, name, width=600, height=900, **kwargs):
        url = f"https://covers.example/{name}"
        self.payloads[url] = image_bytes(width, height, **kwargs)
        return url

    async def choose(self, urls, metadata, preferred=None):
        return await self.checker.choose(urls, metadata, preferred, target=self.target)

    async def test_tall_stacked_primary_is_rejected_and_single_poster_is_selected(self):
        stacked = self.candidate("primary", 800, 900, stacked=True)
        poster = self.candidate("poster")
        self.runtime.reason.return_value = assessments(
            (0, "stacked", "zh"), (1, "single_cover", "zh")
        )
        decision = await self.choose([stacked, poster], {}, preferred=0)
        self.assertEqual(decision.asset.url, poster)
        self.assertEqual(decision.asset.data, self.payloads[poster])
        self.assertEqual(decision.checks[0]["layout"], "stacked")
        self.assertEqual(self.runtime.reason.await_args.args[0], "cover_quality")
        self.assertEqual(len(self.runtime.reason.await_args.kwargs["images"]), 2)

    async def test_real_dimensions_override_upstream_portrait_metadata(self):
        landscape = self.candidate("landscape", 900, 600)
        poster = self.candidate("poster")
        self.runtime.reason.return_value = assessments((1, "single_cover", "zh"))
        decision = await self.choose(
            [landscape, poster], {landscape: {"width": 600, "height": 900}}
        )
        self.assertEqual(decision.asset.url, poster)
        self.assertEqual(decision.checks[0]["width"], 900)
        self.assertEqual(
            self.runtime.reason.await_args.args[1]["covers"],
            [{"cover": 1, "width": 600, "height": 900, "official_for_target": False}],
        )

    async def test_large_images_are_resized_for_inspection_but_original_bytes_are_kept(
        self,
    ):
        poster = self.candidate("large", 1000, 1600, compress_level=0)
        self.assertGreater(len(self.payloads[poster]), 2 * 1024 * 1024)
        self.runtime.reason.return_value = assessments((0, "single_cover", "zh"))
        decision = await self.choose([poster], {})
        self.assertEqual(decision.asset.preview.height, 1600)
        self.assertLess(len(decision.asset.preview.uri), len(decision.asset.data))
        self.assertEqual(decision.asset.data, self.payloads[poster])

    async def test_all_bad_layouts_and_uncertain_results_are_preserved_for_review(self):
        poster = self.candidate("candidate")
        for layout in ("stacked", "collage", "screenshot", "packaging", "unknown"):
            self.runtime.reason.return_value = assessments((0, layout, "zh"))
            decision = await self.choose([poster], {})
            self.assertIsNone(decision.asset)
            self.assertTrue(decision.reason)

    async def test_non_chinese_fallback_still_requires_verified_single_cover(self):
        poster = self.candidate("original")
        self.runtime.reason.return_value = assessments((0, "single_cover", "other"))
        for fallback in ("keep", "review", "original"):
            self.runtime.settings.cover_fallback = fallback
            decision = await self.choose([poster], {})
            self.assertEqual(decision.asset is not None, fallback == "original")
        self.runtime.reason.return_value = assessments((0, "stacked", "other"))
        self.assertIsNone((await self.choose([poster], {})).asset)

    async def test_language_and_resolution_preferences_apply_only_to_accepted_posters(
        self,
    ):
        urls = [
            self.candidate("small"),
            self.candidate("large", 800, 1200),
            self.candidate("collage", 1000, 1500),
        ]
        self.runtime.reason.return_value = assessments(
            (0, "single_cover", "zh"), (1, "single_cover", "zh"), (2, "collage", "zh")
        )
        self.assertEqual((await self.choose(urls, {}, preferred=2)).asset.url, urls[1])

    async def test_unknown_indexes_failed_models_and_disabled_vision_cannot_bypass_validation(
        self,
    ):
        poster = self.candidate("poster")
        self.runtime.reason.return_value = assessments((99, "single_cover", "zh"))
        self.assertIsNone((await self.choose([poster], {})).asset)
        for error in (ModelError("unavailable"), AgentBudget("budget exhausted")):
            self.runtime.reason.side_effect = error
            self.assertIsNone((await self.choose([poster], {})).asset)
        self.runtime.settings.vision = False
        self.runtime.reason.reset_mock()
        self.assertIsNone((await self.choose([poster], {})).asset)
        self.runtime.reason.assert_not_awaited()
        self.runtime.settings.vision = True
        self.runtime.check.side_effect = AgentStopped()
        with self.assertRaises(AgentStopped):
            await self.choose([poster], {})

    async def test_edition_and_recommendation_beat_a_larger_cross_listed_poster(self):
        official = self.candidate("original", 411, 560)
        shared = self.candidate("shared", 787, 1080, stacked=True)
        variant = self.candidate("other-design", 900, 1200, stacked=True)
        self.target.update(titles=["恋愛、借りちゃいました", "Original Game"])
        verdict = assessments(*[(i, "single_cover", "other") for i in range(3)])
        verdict["covers"][0]["visible_title"] = "ASa Project"
        verdict["covers"][1]["visible_title"] = "恋愛、借りちゃいました"
        self.runtime.reason.return_value = verdict
        found = await self.choose([shared, official, variant], {}, preferred=1)
        self.assertEqual(found.selected, 1)
        self.assertFalse(found.checks[0]["identity_verified"])
        self.assertEqual(
            found.asset.preview.digest,
            hashlib.sha256(self.payloads[official]).hexdigest(),
        )

    async def test_fandisc_needs_distinctive_title_or_trusted_edition_binding(self):
        url = self.candidate("cover")
        self.target.update(
            titles=["Series", "Series: Tsubaki & Chinatsu"], ambiguous_titles=["Series"]
        )
        verdict = assessments((0, "single_cover", "zh"))
        item = verdict["covers"][0]
        self.runtime.reason.return_value = verdict
        for title in ["Series", "Series: Emi & Hasumi", "ASa Project"]:
            item["visible_title"] = title
            self.assertIsNone((await self.choose([url], {})).asset)
        item["visible_title"] = "Series: Tsubaki & Chinatsu"
        self.assertIsNotNone((await self.choose([url], {})).asset)
        item.update(visible_title="", basis="official_asset")
        self.assertIsNone(
            (await self.choose([url], {url: {"official_work_id": "2"}})).asset
        )
        self.assertIsNotNone(
            (await self.choose([url], {url: {"official_work_id": "1"}})).asset
        )
        item["identity"] = "mismatch"
        self.assertIsNone(
            (await self.choose([url], {url: {"official_work_id": "1"}})).asset
        )

    async def test_saved_edition_id_conflict_blocks_even_a_recommended_cover(self):
        with patch("services.agent.metadata._build_scrapers", return_value=[]):
            catalog = Catalog(self.config, None, self.runtime)
        catalog.results = [
            ScraperResult(
                title="Original Game",
                source_name="nextmoe",
                source_id="878",
                cover_url=self.candidate("wrong"),
            )
        ]
        self.runtime.reason.return_value = {
            "candidate": 0,
            "cover": 0,
            "evidence": "Similar title",
        }
        result, _ = await select_metadata(
            self.runtime, catalog, {"saved_ids": {"nextmoe_id": "122"}}
        )
        self.assertEqual(result.cover_url, "")
        self.assertIn("ID 冲突", catalog.cover_review)
        self.assertEqual(self.runtime.reason.await_count, 1)
        await catalog.close()

    async def test_selection_is_checked_even_if_model_did_not_inspect_the_cover(self):
        bad = self.candidate("bad", 800, 900, stacked=True)
        other_work = self.candidate("other-work")
        with patch("services.agent.metadata._build_scrapers", return_value=[]):
            catalog = Catalog(self.config, None, self.runtime)
        catalog.cover_checker = self.checker
        catalog.results = [
            ScraperResult(title="One", source_id="1", cover_url=bad),
            ScraperResult(title="Other", source_id="2", cover_url=other_work),
        ]
        self.runtime.reason.side_effect = [
            {"candidate": 0, "cover": 0, "evidence": "Same title"},
            assessments((0, "stacked", "zh")),
        ]
        result, _ = await select_metadata(self.runtime, catalog, {})
        self.assertEqual(result.cover_url, "")
        self.assertIsNone(catalog.cover_data)
        self.assertTrue(catalog.cover_review)
        self.assertNotIn(other_work, self.requests)

    async def test_fill_missing_keeps_existing_cover_without_spending_vision_calls(
        self,
    ):
        with patch("services.agent.metadata._build_scrapers", return_value=[]):
            catalog = Catalog(self.config, None, self.runtime)
        catalog.results = [
            ScraperResult(title="Game", cover_url=self.candidate("unused"))
        ]
        self.runtime.reason.return_value = {
            "candidate": 0,
            "cover": 0,
            "evidence": "Same title",
        }
        result, _ = await select_metadata(
            self.runtime, catalog, {"replace_cover": False}
        )
        self.assertEqual(result.cover_url, "")
        self.assertEqual(self.runtime.reason.await_count, 1)
        self.assertEqual(self.requests, [])
        await catalog.close()


class AgentCoverApplyTests(unittest.IsolatedAsyncioTestCase):
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
        self.game = Game(
            name="Game",
            root_id=0,
            folder_path="/virtual/game",
            developer="Studio",
            description="Description",
        )
        self.session.add(self.game)
        await self.session.commit()
        self.client = httpx.AsyncClient(
            transport=httpx.MockTransport(lambda _: httpx.Response(500))
        )

    async def asyncTearDown(self):
        await self.client.aclose()
        await self.session.close()
        await self.engine.dispose()

    async def test_record_distinguishes_recommendation_validation_and_successful_write(
        self,
    ):
        candidate = ScraperResult(
            title="中文名",
            cover_titles=["Japanese Edition"],
            source_id="122",
            source_name="nextmoe",
            cover_url="shared",
            cover_urls=["poster"],
        )
        related = ScraperResult(
            title="Other Edition",
            source_id="878",
            source_name="nextmoe",
            cover_url="shared",
        )
        source = SimpleNamespace(
            source_name="nextmoe",
            search=AsyncMock(return_value=[candidate, related]),
            search_best=AsyncMock(return_value=None),
            close=AsyncMock(),
        )
        good = image_bytes(411, 560)

        async def asset(url):
            data = good if url == "poster" else image_bytes(787, 1080)
            return CoverAsset(url, data, image_preview(data))

        async def reason(skill, ctx, schema, tools=None, **kwargs):
            if skill == "metadata":
                await tools["search"][1]({"query": "Game"})
                return {"candidate": 0, "cover": 0, "evidence": "Matched source record"}
            self.assertEqual(ctx["target"]["source_id"], "122")
            self.assertIn("Japanese Edition", ctx["target"]["titles"])
            self.assertEqual(ctx["target"]["cross_listed_covers"], [0])
            verdict = assessments(
                (0, "single_cover", "zh"), (1, "single_cover", "other")
            )
            verdict["covers"][0].update(
                identity="unknown", basis="none", visible_title=""
            )
            verdict["covers"][1]["visible_title"] = "Japanese Edition"
            return verdict

        job = AgentJob(kind="scrape", request={"retry": True})
        self.session.add(job)
        await self.session.commit()
        runtime = SimpleNamespace(
            session=self.session,
            job=job,
            check=AsyncMock(),
            reason=reason,
            settings=AgentSettings(vision=True, update_mode="overwrite"),
        )
        with (
            patch("services.agent.metadata._build_scrapers", return_value=[source]),
            patch.object(CoverChecker, "load", side_effect=asset),
        ):
            with patch(
                "services.scraper.orchestrator._save_verified_image",
                side_effect=OSError("unwritable"),
            ):
                await scrape_game(runtime, self.game, self.client)
            await scrape_game(runtime, self.game, self.client)
        first, second = (
            await self.session.scalars(select(AgentResult).order_by(AgentResult.id))
        ).all()
        self.assertEqual(first.status, "partial")
        self.assertIsNone(first.data["cover_decision"]["saved_sha256"])
        self.assertIsNone(first.data["cover_decision"]["saved"])
        self.assertEqual(second.status, "applied")
        audit = second.data["cover_decision"]
        self.assertEqual(
            (audit["recommended"], audit["selected"], audit["saved"]), (0, 1, 1)
        )
        self.assertEqual(
            audit["saved_sha256"],
            hashlib.sha256(Path(self.game.cover_path).read_bytes()).hexdigest(),
        )
        self.assertEqual(Path(self.game.cover_path).read_bytes(), good)

    async def test_apply_saves_the_verified_bytes_without_downloading_a_different_image(
        self,
    ):
        data = image_bytes(600, 900)
        with patch(
            "services.scraper.orchestrator._download_cover", new_callable=AsyncMock
        ) as download:
            await _apply_result(
                ScraperResult(cover_url="https://covers.example/mutable"),
                "steam",
                self.game,
                self.client,
                self.config.covers_path,
                self.session,
                self.config,
                "overwrite",
                cover_data=data,
            )
            await self.session.commit()
            download.assert_not_awaited()
        self.assertEqual(Path(self.game.cover_path).read_bytes(), data)

    async def test_regular_fallback_cannot_restore_an_unverified_cover(self):
        source = SimpleNamespace(
            source_name="steam",
            search_best=AsyncMock(
                return_value=ScraperResult(
                    source_name="steam",
                    cover_url="https://covers.example/stacked",
                    description="Fallback description",
                )
            ),
        )
        with patch(
            "services.scraper.orchestrator._download_cover", new_callable=AsyncMock
        ) as download:
            await scrape_single_game(
                self.game,
                [source],
                self.client,
                self.config.covers_path,
                self.session,
                self.config,
                "missing",
                allow_cover=False,
            )
            download.assert_not_awaited()
        self.assertIsNone(self.game.cover_path)

    async def test_cached_local_cover_reuse_also_respects_the_guard(self):
        path = self.config.covers_path / "existing.png"
        path.write_bytes(image_bytes(800, 900, stacked=True))
        other = Game(
            name=self.game.name,
            root_id=0,
            folder_path="/virtual/other",
            cover_path=str(path),
        )
        self.session.add(other)
        await self.session.commit()
        await _reuse_existing_metadata(
            self.session,
            self.game,
            self.config.covers_path,
            self.config,
            "missing",
            allow_cover=False,
        )
        self.assertIsNone(self.game.cover_path)
        self.assertFalse(
            (self.config.covers_path / f"{self.game.id}_reused.png").exists()
        )

    async def test_agent_failure_passes_the_cover_guard_to_fallback(self):
        job = AgentJob(kind="scrape", request={})
        self.session.add(job)
        await self.session.commit()
        runtime = SimpleNamespace(
            session=self.session,
            job=job,
            settings=AgentSettings(portrait=True),
            check=AsyncMock(),
        )
        with (
            patch("services.agent.metadata._build_scrapers", return_value=[]),
            patch(
                "services.agent.jobs.select_metadata",
                side_effect=ModelError("Unavailable"),
            ),
            patch(
                "services.agent.jobs.scrape_single_game", new_callable=AsyncMock
            ) as fallback,
        ):
            await scrape_game(runtime, self.game, self.client)
            self.assertFalse(fallback.await_args.kwargs["allow_cover"])
        self.assertIsNone(self.game.cover_path)
        self.assertEqual(
            (await self.session.execute(select(AgentResult.status))).scalar_one(),
            "model_fallback",
        )

    async def test_failed_cover_validation_is_retryable_and_fallback_does_not_replace_it(
        self,
    ):
        job = AgentJob(kind="scrape", request={})
        self.session.add(job)
        await self.session.commit()
        runtime = SimpleNamespace(
            session=self.session,
            job=job,
            settings=AgentSettings(portrait=True, vision=True),
            check=AsyncMock(),
        )
        result = ScraperResult(
            title=self.game.name,
            source_name="steam",
            cover_url="https://covers.example/stacked",
        )
        source = SimpleNamespace(
            source_name="steam",
            search_best=AsyncMock(return_value=result),
            close=AsyncMock(),
        )

        async def metadata(runtime, catalog, context):
            catalog.selection = SimpleNamespace(platforms={})
            catalog.cover_review = "拼接图未通过校验，保留现有封面"
            return result, "Verified identity"

        with (
            patch("services.agent.metadata._build_scrapers", return_value=[source]),
            patch(
                "services.agent.jobs.select_metadata", side_effect=metadata
            ) as select_metadata,
            patch(
                "services.scraper.orchestrator._download_cover", new_callable=AsyncMock
            ) as download,
        ):
            await scrape_game(runtime, self.game, self.client)
            await scrape_game(runtime, self.game, self.client)
            self.assertEqual(select_metadata.await_count, 2)
            download.assert_not_awaited()
        self.assertIsNone(self.game.cover_path)
        self.assertEqual(
            list((await self.session.execute(select(AgentResult.status))).scalars()),
            ["partial", "partial"],
        )
