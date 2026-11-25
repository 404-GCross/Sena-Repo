import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch

from fastapi import HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

import config
import database
from api import games, platforms
from cli import backup
from models.agent import AgentJob
from models.game import Game, GameVersion, PlatformCategory, PlatformCategoryRule
from models.root_directory import RootDirectory
from models.user import User
from schemas.agent import AgentSettings
from services.agent.jobs import scrape_game
from services.file_source import FileEntry
from services.importer import import_from_root
from services.platforms import load_platform_rules
from services.scanner import ArchiveFile, CompanyFolder, GameFolder, ScanResult
from services.scraper.base import ScraperResult
from utils.regex_patterns import PlatformRule, match_platform


class PlatformDefaultsTests(unittest.IsolatedAsyncioTestCase):
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
        self.user = User(id=1, role="admin", status="active")

    async def asyncTearDown(self):
        await self.engine.dispose()

    async def seed_game(self, session, versions):
        root = RootDirectory(path=str(Path(self.temp.name) / "library"))
        session.add(root)
        await session.flush()
        game = Game(
            name="Test Game",
            root_id=root.id,
            folder_path=root.path + "/game",
            description="Existing description",
            developer="Studio",
            cover_path="cover.jpg",
        )
        session.add(game)
        await session.flush()
        rows = []
        for index, (platform, fallback) in enumerate(versions):
            version = GameVersion(
                game_id=game.id,
                filename=f"file-{index}.zip",
                file_path=f"{game.folder_path}/file-{index}.zip",
                platform=platform,
                platform_is_fallback=fallback,
            )
            session.add(version)
            rows.append(version)
        await session.commit()
        return game, rows

    async def test_default_rules_use_pc_without_shadowing_other_categories(self):
        async with self.sessions() as session:
            rules = await load_platform_rules(session, self.config)
            categories = await platforms.list_platforms(self.user, session)
        self.assertEqual([c.name for c in categories], ["PC", "手机模拟器", "安卓直装", "iOS"])
        for filename, expected in {
            "Game.zip": "PC",
            "Game[PC].7z": "PC",
            "Game[KR].zip": "手机模拟器",
            "Game[KRKR].rar": "手机模拟器",
            "KR_Game.7z": "手机模拟器",
            "Game_kirikiroid.zip": "手机模拟器",
            "Game[ONS].zip": "手机模拟器",
            "Game_ONScripter.7z": "手机模拟器",
            "Game[手机模拟器].zip": "手机模拟器",
            "Game（Ty）.zip": "手机模拟器",
            "Game[Ar].zip": "手机模拟器",
            "Game_tyranor.zip": "手机模拟器",
            "Game[安卓直装].zip": "安卓直装",
            "直装_Game.apk": "安卓直装",
            "Game[KRKR][iOS].APK": "安卓直装",
            "Game[直装].ipa": "iOS",
            "Game[PC][ONS].IPA": "iOS",
            "游戏[iOS].zip": "iOS",
            "iOS直装_游戏.7z": "iOS",
            "Studios.zip": "PC",
        }.items():
            with self.subTest(filename=filename):
                self.assertEqual(match_platform(filename, rules), expected)
        self.assertEqual(match_platform("Game.zip", []), "PC")
        self.assertEqual(
            match_platform("Game.zip", [PlatformRule("未分类", "regex", ".*")]), "PC"
        )
        self.assertEqual(
            match_platform("Game.zip", [PlatformRule("Switch", "keyword", "game")]),
            "Switch",
        )

    async def test_ipa_import_from_local_and_remote_sources(self):
        directory = Path(self.temp.name) / "library"
        directory.mkdir()
        (directory / "本地[PC].IPA").touch()
        self.config._scan_depth = 0
        remote_file = FileEntry("网盘[直装].ipa", "/library/网盘[直装].ipa", False, 30)
        async with self.sessions() as session:
            local = RootDirectory(path=str(directory))
            remote = RootDirectory(path="openlist://0/library", source_type="openlist", source_path="/library")
            session.add_all([local, remote])
            await session.commit()
            await import_from_root(local.id, self.config, session)
            with patch("services.importer.adapter_from_source", return_value=SimpleNamespace(list=lambda _: [remote_file])):
                await import_from_root(remote.id, self.config, session)
            versions = (await session.scalars(select(GameVersion))).all()
            self.assertEqual({(v.filename, v.platform, v.platform_is_fallback) for v in versions}, {
                ("本地[PC].IPA", "iOS", False), ("网盘[直装].ipa", "iOS", False),
            })
            categories = await platforms.list_platforms(self.user, session)
            self.assertEqual(next(c.version_count for c in categories if c.name == "iOS"), 2)

    async def test_existing_platform_categories_are_not_reseeded(self):
        async with self.sessions() as session:
            emulator = await session.scalar(select(PlatformCategory).where(PlatformCategory.name == "手机模拟器"))
            emulator.name = "KRKR"
            _, versions = await self.seed_game(session, [("KRKR", False)])
            version_id = versions[0].id
        await database.create_tables()
        async with self.sessions() as session:
            self.assertEqual((await session.get(GameVersion, version_id)).platform, "KRKR")
            self.assertNotIn("手机模拟器", [c.name for c in await platforms.list_platforms(self.user, session)])

    async def test_upgrade_moves_legacy_versions_and_preserves_existing_choices(self):
        async with self.sessions() as session:
            _, versions = await self.seed_game(
                session, [("未分类", False), ("PC", False), ("ONS", False)]
            )
            ids = [version.id for version in versions]
            legacy = PlatformCategory(name="未分类", sort_order=100000, is_system=True)
            session.add(legacy)
            await session.flush()
            session.add(
                PlatformCategoryRule(
                    category_id=legacy.id, kind="keyword", pattern="legacy"
                )
            )
            await session.commit()
        async with self.engine.begin() as conn:
            await conn.exec_driver_sql(
                "ALTER TABLE game_versions DROP COLUMN platform_is_fallback"
            )
            await conn.exec_driver_sql(
                "UPDATE platform_categories SET is_system = 0 WHERE name = 'PC'"
            )
        await database.create_tables()
        await database.create_tables()
        async with self.sessions() as session:
            rows = [await session.get(GameVersion, version_id) for version_id in ids]
            self.assertEqual(
                [(row.platform, row.platform_is_fallback) for row in rows],
                [("PC", True), ("PC", False), ("ONS", False)],
            )
            self.assertIsNone(
                (
                    await session.execute(
                        select(PlatformCategory).where(
                            PlatformCategory.name == "未分类"
                        )
                    )
                ).scalar_one_or_none()
            )
            pc = (
                await session.execute(
                    select(PlatformCategory).where(PlatformCategory.name == "PC")
                )
            ).scalar_one()
            self.assertTrue(pc.is_system)
            rules = await load_platform_rules(session)
            self.assertTrue(any(rule.category == "PC" for rule in rules))
            self.assertFalse(any(rule.pattern == "legacy" for rule in rules))

    async def test_upgrade_restores_pc_when_it_was_renamed(self):
        async with self.engine.begin() as conn:
            await conn.exec_driver_sql(
                "UPDATE platform_categories SET name = 'Desktop', is_system = 0 WHERE name = 'PC'"
            )
        await database.create_tables()
        async with self.sessions() as session:
            categories = {
                row.name: row
                for row in (await session.execute(select(PlatformCategory))).scalars()
            }
            self.assertTrue(categories["PC"].is_system)
            self.assertIn("Desktop", categories)
            self.assertFalse(categories["Desktop"].is_system)

    async def test_pc_is_protected_but_rules_and_priority_remain_editable(self):
        async with self.sessions() as session:
            pc = (
                await session.execute(
                    select(PlatformCategory).where(PlatformCategory.name == "PC")
                )
            ).scalar_one()
            with self.assertRaises(HTTPException):
                await platforms.delete_platform(
                    pc.id, reassign_to_id=None, user=self.user, session=session
                )
            with self.assertRaises(HTTPException):
                await platforms.update_platform(
                    pc.id,
                    platforms.PlatformCategoryUpdate(name="Other"),
                    self.user,
                    session,
                )
            with self.assertRaises(HTTPException):
                await platforms.create_platform(
                    platforms.PlatformCategoryCreate(name="未分类"), self.user, session
                )
            rule = await platforms.create_rule(
                pc.id,
                platforms.PlatformRuleCreate(kind="keyword", pattern="desktop"),
                self.user,
                session,
            )
            session.expire(pc, ["rules"])
            await platforms.update_rule(
                pc.id,
                rule.id,
                platforms.PlatformRuleUpdate(pattern="windows"),
                self.user,
                session,
            )
            await platforms.reorder_rules(
                pc.id,
                platforms.PlatformRuleOrderUpdate(ids=[rule.id]),
                self.user,
                session,
            )
            self.assertEqual(
                (
                    await platforms.test_match(
                        platforms.TestMatchRequest(filename="windows.zip"),
                        self.user,
                        session,
                    )
                )["category"],
                "PC",
            )
            await platforms.reorder_platforms(
                platforms.PlatformOrderUpdate(ids=[pc.id]), self.user, session
            )
            await platforms.delete_rule(pc.id, rule.id, self.user, session)

    async def test_scan_can_refine_fallback_pc_but_preserves_manual_pc_and_locks(self):
        async with self.sessions() as session:
            root = RootDirectory(path=self.temp.name)
            session.add(root)
            await session.commit()
            result = ScanResult(
                self.temp.name,
                [
                    CompanyFolder(
                        "Studio",
                        self.temp.name,
                        [
                            GameFolder(
                                name,
                                f"{self.temp.name}/{name}",
                                [
                                    ArchiveFile(
                                        "game.zip",
                                        f"{self.temp.name}/{name}/game.zip",
                                        10,
                                    )
                                ],
                            )
                            for name in ("fallback", "manual", "locked")
                        ],
                    )
                ],
            )
            await import_from_root(root.id, self.config, session, scan_override=result)
            versions = list(
                (
                    await session.execute(select(GameVersion).order_by(GameVersion.id))
                ).scalars()
            )
            self.assertTrue(
                all(v.platform == "PC" and v.platform_is_fallback for v in versions)
            )
            await games.update_version(
                versions[1].game_id,
                versions[1].id,
                games.VersionUpdate(platform="PC"),
                self.user,
                session,
            )
            (await session.get(Game, versions[2].game_id)).metadata_locked = True
            emulator = (
                await session.execute(
                    select(PlatformCategory).where(PlatformCategory.name == "手机模拟器")
                )
            ).scalar_one()
            session.add(
                PlatformCategoryRule(
                    category_id=emulator.id, kind="keyword", pattern="game.zip"
                )
            )
            await session.commit()
            await import_from_root(root.id, self.config, session, scan_override=result)
            for version in versions:
                await session.refresh(version)
            self.assertEqual(
                [(v.platform, v.platform_is_fallback) for v in versions],
                [("手机模拟器", False), ("PC", False), ("PC", True)],
            )

    async def test_agent_retries_fallback_pc_without_overwriting_manual_pc(self):
        async with self.sessions() as session:
            game, versions = await self.seed_game(
                session, [("PC", True), ("PC", False)]
            )
            job = AgentJob(kind="scrape", request={})
            session.add(job)
            await session.commit()
            runtime = SimpleNamespace(
                session=session, job=job, settings=AgentSettings(), check=AsyncMock()
            )
            attempts = []

            async def select_metadata(runtime, catalog, context):
                attempts.append(context)
                values = (
                    {} if len(attempts) == 1 else {str(v.id): "手机模拟器" for v in versions}
                )
                catalog.selection = SimpleNamespace(platforms=values)
                return ScraperResult(
                    title=game.name, source_name="steam"
                ), "Verified files"

            with (
                patch("services.agent.metadata._build_scrapers", return_value=[]),
                patch(
                    "services.agent.jobs.select_metadata", side_effect=select_metadata
                ),
                patch("services.agent.jobs._apply_result", new_callable=AsyncMock),
            ):
                await scrape_game(runtime, game, None)
                self.assertEqual(
                    (versions[0].platform, versions[0].platform_is_fallback),
                    ("PC", True),
                )
                await scrape_game(runtime, game, None)
                await scrape_game(runtime, game, None)
            self.assertEqual(len(attempts), 2)
            self.assertTrue(attempts[0]["files"][0]["platform_is_fallback"])
            self.assertEqual(
                [(v.platform, v.platform_is_fallback) for v in versions],
                [("手机模拟器", False), ("PC", False)],
            )

    async def test_agent_preserves_pc_confirmed_while_metadata_is_applying(self):
        async with self.sessions() as session:
            game, versions = await self.seed_game(session, [("PC", True)])
            job = AgentJob(kind="scrape", request={})
            session.add(job)
            await session.commit()
            runtime = SimpleNamespace(
                session=session, job=job, settings=AgentSettings(), check=AsyncMock()
            )

            async def select_metadata(runtime, catalog, context):
                catalog.selection = SimpleNamespace(
                    platforms={str(versions[0].id): "手机模拟器"}
                )
                return ScraperResult(title=game.name), "Verified files"

            async def apply(*args, **kwargs):
                async with self.sessions() as other:
                    await games.update_version(
                        game.id,
                        versions[0].id,
                        games.VersionUpdate(platform="PC"),
                        self.user,
                        other,
                    )

            with (
                patch("services.agent.metadata._build_scrapers", return_value=[]),
                patch(
                    "services.agent.jobs.select_metadata", side_effect=select_metadata
                ),
                patch("services.agent.jobs._apply_result", side_effect=apply),
            ):
                await scrape_game(runtime, game, None)
            await session.refresh(versions[0])
            self.assertEqual(
                (versions[0].platform, versions[0].platform_is_fallback), ("PC", False)
            )

    async def test_backup_roundtrip_and_legacy_restore_keep_fallback_provenance(self):
        async with self.sessions() as session:
            _, versions = await self.seed_game(
                session, [("PC", True), ("PC", False), ("PC", True)]
            )
            library = await backup._export_library(session)
            library["platform_categories"] = await backup._export_platform_categories(
                session
            )
            self.assertEqual(
                [v["platform_is_fallback"] for v in library["versions"]], [True, False, True]
            )
            library["versions"][0]["platform"] = "未分类"
            library["versions"][0].pop("platform_is_fallback")
            library["platform_categories"].append(
                {"name": "未分类", "is_system": True, "rules": []}
            )
            await backup.import_library(
                self.config,
                session,
                library,
                replace=True,
                source_map={},
                available_media={"covers": set(), "backgrounds": set()},
                overwrite_media=False,
            )
            await session.commit()
            for version in versions:
                await session.refresh(version)
            self.assertEqual(
                [(v.platform, v.platform_is_fallback) for v in versions],
                [("PC", True), ("PC", False), ("PC", True)],
            )
            names = set(
                (await session.execute(select(PlatformCategory.name))).scalars()
            )
            self.assertNotIn("未分类", names)
            rules = await load_platform_rules(session)
            self.assertTrue(any(rule.category == "PC" for rule in rules))
