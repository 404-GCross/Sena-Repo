import json
import tempfile
import unittest
from datetime import timedelta
from pathlib import Path
from unittest.mock import Mock, patch

import httpx
from fastapi import FastAPI, HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

import config
import database
from api import auth, roots, settings, steam_patch
from models.file_source import SteamPatchRoot
from models.game import Game, GameVersion
from models.root_directory import RootDirectory
from models.user import User
from services.file_source import OpenListFileSource, SourceUnavailable
from services.importer import import_from_root


class ProxyPrivacy(unittest.IsolatedAsyncioTestCase):
    async def test_diagnostics_admin_only_credentials_never_returned_or_logged(self):
        app = FastAPI()
        app.include_router(settings.router)
        user = User(id=1, role="user", status="active")
        app.dependency_overrides[auth.get_current_user] = lambda: user
        cfg = config.Config(
            proxy="http://fixture-user:fixture-password@private.example:8080"
        )
        cfg.scrapers.enabled_scrapers = ["nextmoe"]
        cfg.scrapers.nextmoe_api_key = "test-fixture-not-a-real-key"
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app), base_url="http://fixture"
        ) as client:
            with (
                patch("config.load_config", return_value=cfg),
                patch("config.reload_persisted_scraper_config"),
                patch("httpx.AsyncClient") as transport,
            ):
                blocked = await client.post("/api/settings/proxy-test")
                self.assertEqual(blocked.status_code, 403)
                transport.assert_not_called()
                info = (await client.get("/api/settings/scraper")).json()
                self.assertEqual(info["enabled_scrapers"], ["nextmoe"])
                self.assertEqual((info["proxy"], info["nextmoe_api_key"]), ("", ""))
                user.role = "admin"
                get = transport.return_value.__aenter__.return_value.get
                response = httpx.Response(
                    200, request=httpx.Request("GET", "https://example.org")
                )
                response.elapsed = timedelta(milliseconds=42)
                get.side_effect = [response, httpx.ConnectError(cfg.proxy)]
                with self.assertLogs("api.settings", level="INFO") as captured:
                    ok = await client.post("/api/settings/proxy-test")
                    failed = await client.post("/api/settings/proxy-test")
                self.assertEqual(
                    ok.json(), {"ok": True, "status": 200, "latency_ms": 42}
                )
                self.assertFalse(failed.json()["ok"])
                for value in (ok.text, failed.text, *captured.output):
                    for private in (
                        "fixture-user",
                        "fixture-password",
                        "private.example",
                    ):
                        self.assertNotIn(private, value)


class RemotePages(unittest.TestCase):
    @staticmethod
    def page(start, end, total):
        return {
            "total": total,
            "content": [
                {"name": f"g{i}.zip", "is_dir": False} for i in range(start, end)
            ],
        }

    def test_short_pages_require_the_full_unique_total(self):
        source = object.__new__(OpenListFileSource)
        source._post = Mock(
            side_effect=[self.page(0, 60, 120), self.page(60, 120, 120)]
        )
        self.assertEqual(len(source.list("/")), 120)
        self.assertEqual(source._post.call_count, 2)
        for last in (
            self.page(0, 100, 150),
            self.page(100, 100, 150),
            self.page(100, 151, 151),
            {"total": 150},
        ):
            source._post = Mock(side_effect=[self.page(0, 100, 150), last] * 2)
            with self.assertRaises(SourceUnavailable):
                source.list("/")
            self.assertEqual(source._post.call_count, 4)

    def test_retry_starts_a_new_snapshot(self):
        source = object.__new__(OpenListFileSource)
        source._post = Mock(
            side_effect=[self.page(0, 1, 3), self.page(0, 1, 3), self.page(20, 22, 2)]
        )
        self.assertEqual([f.name for f in source.list("/")], ["g20.zip", "g21.zip"])
        self.assertEqual(
            [c.args[1]["page"] for c in source._post.call_args_list], [1, 2, 1]
        )


class ScanIntegrity(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.path = Path(tmp.name)
        self.cfg = config.Config(
            data_path=str(self.path / "data"), patch_dir=str(self.path / "patches")
        )
        self.engine = create_async_engine(self.cfg.database_url)
        self.sessions = async_sessionmaker(self.engine, expire_on_commit=False)
        for mock in (
            patch.object(config, "_cached_config", self.cfg),
            patch.object(database, "_engine", self.engine),
            patch.object(database, "_session_factory", self.sessions),
            patch.dict(roots._scan_state, {"status": "idle"}),
            patch.dict(steam_patch._patch_scan_state, {"status": "idle"}),
        ):
            mock.start()
            self.addCleanup(mock.stop)
        await database.create_tables()
        self.cfg._scan_depth = 0

    async def asyncTearDown(self):
        await self.engine.dispose()

    async def seed(self):
        directory = self.path / "games"
        directory.mkdir()
        async with self.sessions() as s:
            root = RootDirectory(path=str(directory))
            s.add(root)
            await s.commit()
            self.assertEqual(
                (await import_from_root(root.id, self.cfg, s))["total_games"], 0
            )
            for name in ("a.zip", "b.zip"):
                (directory / name).touch()
            await import_from_root(root.id, self.cfg, s)
            return root.id, directory

    async def visible(self):
        async with self.sessions() as s:
            return list(
                await s.scalars(select(Game.id).where(Game.is_deleted.is_(False)))
            )

    async def test_missing_empty_recovery_and_partial_removal(self):
        rid, directory = await self.seed()
        before = await self.visible()
        self.assertEqual(len(before), 2)
        directory.rename(self.path / "unmounted")
        for create in (False, True):
            if create:
                directory.mkdir()
            result = await roots._run_scan(self.cfg, [rid])
            self.assertEqual(result["failed_roots"], [rid])
            self.assertEqual(await self.visible(), before)
            self.assertEqual(roots._scan_state["empty_roots"], [rid] if create else [])
        directory.rmdir()
        (self.path / "unmounted").rename(directory)
        (directory / "a.zip").unlink()
        (directory / "new.zip").touch()
        await roots._run_scan(self.cfg, [rid])
        visible = await self.visible()
        self.assertEqual(len(visible), 2)
        self.assertEqual(len(set(visible) & set(before)), 1)

    async def test_explicit_empty_confirmation_is_per_root_and_rechecks_source(self):
        rid, directory = await self.seed()
        for f in directory.iterdir():
            f.unlink()
        result = await roots._run_scan(self.cfg, [rid])
        self.assertEqual(result["status"], "failed")
        async with self.sessions() as s:
            with self.assertRaises(HTTPException):
                await roots.refresh_root(
                    rid, User(id=1), s, confirm_empty=True, after_run="stale"
                )
            directory.rmdir()
            await roots.refresh_root(
                rid,
                User(id=1),
                s,
                confirm_empty=True,
                after_run=roots._scan_state["run_id"],
            )
            await next(iter(roots._background_tasks))
        self.assertEqual(len(await self.visible()), 2)
        directory.mkdir()
        await roots._run_scan(self.cfg, [rid])
        key = roots._scan_state["run_id"]
        async with self.sessions() as s:
            await roots.refresh_root(
                rid, User(id=1), s, confirm_empty=True, after_run=key
            )
            await next(iter(roots._background_tasks))
        self.assertEqual(await self.visible(), [])

    async def test_unreadable_subtree_and_incomplete_remote_pages_cannot_hide_existing_games(
        self,
    ):
        rid, directory = await self.seed()
        before = await self.visible()
        child = directory / "unavailable"
        child.mkdir()
        real_iterdir = Path.iterdir

        def listing(path):
            if path == child:
                raise PermissionError("fixture permission denied")
            return real_iterdir(path)

        with patch.object(Path, "iterdir", listing):
            result = await roots._run_scan(self.cfg, [rid])
            self.assertEqual(result["failed_roots"], [rid])
        self.assertEqual(await self.visible(), before)
        source = object.__new__(OpenListFileSource)
        source._post = Mock(
            side_effect=[RemotePages.page(0, 60, 120), RemotePages.page(60, 60, 120)]
            * 2
        )
        async with self.sessions() as s:
            root = RootDirectory(
                path="openlist://1/Games", source_path="/Games", source_type="openlist"
            )
            s.add(root)
            await s.flush()
            old = Game(
                root_id=root.id,
                entry_source="library",
                name="remote",
                folder_path="openlist://1/Games/previous.zip",
            )
            s.add(old)
            await s.commit()
            with patch("services.importer.adapter_from_source", return_value=source):
                result = await roots._run_scan(self.cfg, [root.id])
                self.assertEqual(result["failed_roots"], [root.id])
            await s.refresh(old)
            self.assertFalse(old.is_deleted)

    async def test_reset_preflights_all_roots_and_failed_root_writes_are_rolled_back(
        self,
    ):
        rid, directory = await self.seed()
        before = await self.visible()
        async with self.sessions() as s:
            root = RootDirectory(path=str(self.path / "other"))
            s.add(root)
            await s.commit()
            other = root.id
        resp = await roots._run_scan(self.cfg, [rid, other], clear_existing=True)
        self.assertEqual(resp["status"], "failed")
        self.assertEqual(before, await self.visible())
        (self.path / "other").mkdir()
        (self.path / "other" / "c.zip").touch()

        async def mixed(key, cfg, s, **kw):
            if key == rid:
                s.add(Game(name="partial", root_id=rid, folder_path="partial"))
                await s.flush()
                raise OSError("fixture write failed")
            return await import_from_root(key, cfg, s, **kw)

        with patch("api.roots.import_from_root", side_effect=mixed):
            resp = await roots._run_scan(self.cfg, [rid, other], clear_existing=True)
        self.assertEqual(resp["failed_roots"], [rid])
        async with self.sessions() as s:
            names = set(await s.scalars(select(Game.name)))
            self.assertEqual(names, {"a", "b", "c"})
            self.assertEqual(len((await s.scalars(select(GameVersion))).all()), 3)

    async def test_patch_all_modes_keep_bytes_until_every_root_verified(self):
        index = steam_patch._get_patch_index_dir(self.cfg)
        index.mkdir()
        f = index / "patches.json"
        old = b'{"patches":[{"file":"keep.zip", "locked":true,"manifest_status":"confirmed"}]}'
        f.write_bytes(old)
        directory = Path(self.cfg.patch_dir)
        async with self.sessions() as s:
            for exists in (False, True):
                if exists:
                    directory.mkdir()
                for mode in ("merge", "metadata", "reset"):
                    with self.assertRaises(HTTPException) as ctx:
                        await steam_patch.scan_patches_endpoint(mode, None, s)
                    self.assertEqual(ctx.exception.status_code, 409)
                    self.assertEqual(f.read_bytes(), old)
                    self.assertEqual(directory.exists(), exists)
            directory.joinpath("keep.zip").touch()
            for invalid in (b"{", b"{}", b'{"patches":[{}]}'):
                f.write_bytes(invalid)
                with (
                    patch("scan_patches._guess_app_id", return_value=None),
                    patch("scan_patches._enrich_identity", return_value=(None, "")),
                ):
                    with self.assertRaises(HTTPException):
                        await steam_patch.scan_patches_endpoint("reset", None, s)
                self.assertEqual(f.read_bytes(), invalid)
            f.write_bytes(old)
            r = SteamPatchRoot(path=str(self.path / "absent"), source_type="local")
            s.add(r)
            s.add(SteamPatchRoot(path=str(directory), source_type="local"))
            await s.commit()
            with self.assertRaises(HTTPException):
                await steam_patch.scan_patches_endpoint("merge", None, s)
            self.assertEqual(f.read_bytes(), old)
            (self.path / "absent").mkdir()
            with (
                patch("scan_patches._guess_app_id", return_value=None),
                patch("scan_patches._enrich_identity", return_value=(None, "")),
            ):
                await steam_patch.scan_patches_endpoint("merge", None, s)
            self.assertEqual(f.with_suffix(".last-good.json").read_bytes(), old)
            self.assertTrue(json.loads(f.read_bytes())["patches"][0]["locked"])

    async def test_confirm_empty_patch_root_does_not_clear_another_roots_rules(self):
        index = steam_patch._get_patch_index_dir(self.cfg)
        index.mkdir()
        directory = Path(self.cfg.patch_dir)
        directory.mkdir()
        other = self.path / "other-patches"
        other.mkdir()
        (other / "another.7z").touch()
        kept = {"file": str(other / "another.7z"), "locked": True, "target_dir": "Data"}
        path = index / "patches.json"
        path.write_text(json.dumps({"patches": [{"file": "old.zip"}, kept]}))
        async with self.sessions() as s:
            r = SteamPatchRoot(path=str(directory), source_type="local")
            s.add(r)
            s.add(SteamPatchRoot(path=str(other), source_type="local"))
            await s.commit()
            with (
                patch("scan_patches._guess_app_id", return_value=None),
                patch("scan_patches._enrich_identity", return_value=(None, "")),
            ):
                with self.assertRaises(HTTPException) as err:
                    await steam_patch.scan_patches_endpoint("merge", None, s)
            detail = err.exception.detail
            self.assertEqual(detail["root_id"], r.id)
            with self.assertRaises(HTTPException):
                await steam_patch.scan_patches_endpoint("merge", None, s, r.id, "stale")
            await steam_patch.scan_patches_endpoint(
                "merge", None, s, r.id, detail["run_id"]
            )
        self.assertEqual(json.loads(path.read_bytes())["patches"], [kept])
