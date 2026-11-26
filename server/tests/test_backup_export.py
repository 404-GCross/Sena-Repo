import json
import os
import stat
import tempfile
import unittest
from contextlib import asynccontextmanager
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from fastapi import UploadFile
from sqlalchemy import select
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

import config
import database
from api import backup as api, setup
from cli import backup, patch_rules
from cli.common import CliError
from models.file_source import FileSource, SteamPatchRoot
from models.game import Game, PlatformCategory, PlatformCategoryRule
from models.user import User, hash_password, verify_password
from services import backup_schedule as schedule
from utils.secrets import decrypt_secret, encrypt_secret


@asynccontextmanager
async def server(directory):
    cfg = config.Config(data_path=str(directory))
    engine = create_async_engine(cfg.database_url)
    sessions = async_sessionmaker(engine, expire_on_commit=False)
    try:
        async with engine.begin() as conn:
            await conn.run_sync(database.Base.metadata.create_all)
        with patch.object(config, "_cached_config", cfg), patch.object(database, "_session_factory", sessions):
            yield cfg, sessions
    finally:
        await engine.dispose()


class BackupExportTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.directory = Path(tmp.name)
        instance = server(self.directory / "source")
        self.cfg, self.sessions = await instance.__aenter__()
        self.addAsyncCleanup(instance.__aexit__, None, None, None)
        self.cover = self.cfg.covers_path / "cover.png"
        self.cover.write_bytes(b"image one")
        async with self.sessions.begin() as session:
            session.add_all([
                Game(name="Title", root_id=0, folder_path="manual/title", entry_source="manual",
                     cover_path=str(self.cover)),
                User(username="reader", password_hash="fixture", salt="test"),
                PlatformCategory(name="Handheld", rules=[PlatformCategoryRule(pattern="archive")]),
            ])

    async def test_auto_tracks_only_selected_data_and_media(self):
        run = backup.run_auto_backup
        await run(self.cfg)
        with patch.object(backup, "utc_iso", return_value="another export time"):
            self.assertEqual(await run(self.cfg), {"skipped": "unchanged"})
        async with self.sessions.begin() as session:
            rule = await session.scalar(select(PlatformCategoryRule))
            rule.pattern = "package"
        self.assertIn("file", await run(self.cfg))
        async with self.sessions.begin() as session:
            user = await session.scalar(select(User))
            user.status = "rejected"
        self.assertIn("file", await run(self.cfg))
        async with self.sessions.begin() as session:
            session.add(FileSource(name="Drive", type="openlist", base_url="https://source.invalid"))
        self.assertIn("file", await run(self.cfg))
        scraper_settings = Path(self.cfg.data_path) / "scraper_config.json"
        scraper_settings.write_text('{"enabled": true}')
        self.assertIn("file", await run(self.cfg))
        scraper_settings.write_text('{\n  "enabled": true\n}')
        self.assertEqual(await run(self.cfg), {"skipped": "unchanged"})
        old_time = self.cover.stat().st_mtime_ns
        self.cover.write_bytes(b"image two")
        os.utime(self.cover, ns=(old_time, old_time))
        self.assertIn("file", await run(self.cfg))
        schedule.update_backup_settings(self.cfg, {"include_media": False})
        self.assertTrue((await run(self.cfg))["file"].endswith(".json"))
        self.cover.write_bytes(b"different")
        self.assertEqual(await run(self.cfg), {"skipped": "unchanged"})
        schedule.update_backup_settings(self.cfg, {"scope": "patch"})
        name = (await run(self.cfg))["file"]
        async with self.sessions.begin() as session:
            user = await session.scalar(select(User))
            user.status = "active"
            session.add(FileSource(name="not a patch source"))
        self.assertEqual(await run(self.cfg), {"skipped": "unchanged"})
        (backup.backup_dir(self.cfg) / name).unlink()
        self.assertIn("file", await run(self.cfg))

    async def test_failed_verification_keeps_previous_archive_and_baseline(self):
        output_dir = backup.backup_dir(self.cfg)
        last = output_dir / (await backup.run_auto_backup(self.cfg))["file"]
        baseline = schedule.load_backup_settings(self.cfg)["last_fingerprint"]
        self.cover.write_bytes(b"second image")
        original_write = backup.write_backup

        def change_during_write(*args, **kwargs):
            self.cover.write_bytes(b"third  image")
            original_write(*args, **kwargs)

        with patch.object(backup, "write_backup", side_effect=change_during_write):
            with self.assertRaises(CliError):
                await backup.run_auto_backup(self.cfg)
        self.assertEqual(list(output_dir.iterdir()), [last])
        self.assertEqual(schedule.load_backup_settings(self.cfg)["last_fingerprint"], baseline)
        with patch.object(Path, "replace", side_effect=OSError("write failure")):
            with self.assertRaises(OSError):
                await backup.run_auto_backup(self.cfg)
        self.assertEqual(list(output_dir.iterdir()), [last])
        self.assertEqual(schedule.load_backup_settings(self.cfg)["last_fingerprint"], baseline)
        self.assertIn("file", await backup.run_auto_backup(self.cfg))
        self.assertNotEqual(schedule.load_backup_settings(self.cfg)["last_fingerprint"], baseline)

    async def test_patch_sources_round_trip_with_gaps_and_duplicate_names(self):
        async with self.sessions.begin() as session:
            session.add_all([
                FileSource(id=2, name="Drive", type="openlist", base_url="https://other.invalid",
                           password="unrelated-fixture"),
                FileSource(id=8, name="Drive", type="openlist", base_url="https://root.invalid"),
                FileSource(id=15, name="Rules", type="openlist", base_url="https://rule.invalid"),
                SteamPatchRoot(path="/patch", source_type="openlist", source_id=8),
            ])
        patch_rules.write_json(patch_rules.patch_index_path(self.cfg), {"patches": [
            {"source_id": "15", "source_type": "openlist", "source_path": "/rule.zip", "app_id": "7"},
            {"source_id": 2, "source_type": "openlist", "source_path": "/unconfigured.zip"},
        ]})
        schedule.update_backup_settings(self.cfg, {"scope": "patch"})
        archive = backup.backup_dir(self.cfg) / (await backup.run_auto_backup(self.cfg))["file"]
        self.assertNotIn("unrelated-fixture", archive.read_text())
        data = backup.normalise_payload(backup.read_backup_payload(archive))
        sources = {s["key"]: s["base_url"] for s in data["library"]["file_sources"]}
        self.assertEqual(len(sources), 2)
        self.assertEqual(sources[data["patch_roots"][0]["source_key"]], "https://root.invalid")
        self.assertEqual(sources[data["rules"][0]["identity"]["source_key"]], "https://rule.invalid")
        async with server(self.directory / "target") as (cfg, sessions):
            async with sessions.begin() as session:
                session.add(FileSource(id=21, name="Drive", type="openlist", base_url="https://other.invalid"))
            await backup.apply_restore(cfg, archive, data, scope="patch", mode="merge", media_policy="skip")
            rules = patch_rules.load_patch_index(patch_rules.patch_index_path(cfg))["patches"]
            async with sessions() as session:
                root = await session.scalar(select(SteamPatchRoot))
                self.assertEqual((await session.get(FileSource, root.source_id)).base_url, "https://root.invalid")
                self.assertEqual((await session.get(FileSource, rules[0]["source_id"])).name, "Rules")
                self.assertEqual((await session.get(FileSource, 21)).base_url, "https://other.invalid")

    async def test_admin_export_and_setup_import_on_fresh_server(self):
        password_hash, salt = hash_password("fixture-password")
        async with self.sessions.begin() as session:
            session.add_all([
                User(username="manager", role="admin", is_admin=True, password_hash=password_hash, salt=salt),
                FileSource(name="Drive", type="openlist", password=encrypt_secret("fixture-source")),
            ])
        entry = await api.export_backup(api.ExportRequest(), SimpleNamespace(id=1))
        self.assertTrue(entry["has_media"])
        archive = backup.backups_root(self.cfg) / entry["name"]
        async with server(self.directory / "fresh") as (cfg, sessions):
            async with sessions() as session:
                result = await setup.import_setup_backup(UploadFile(file=archive.open("rb"), filename="full.zip"), session)
            self.assertEqual(result["stats"]["media_written"], 1)
            self.assertEqual(stat.S_IMODE(Path(result["stored"]).stat().st_mode), 0o600)
            async with sessions() as session:
                user = await session.scalar(select(User).where(User.username == "manager"))
                self.assertTrue(verify_password("fixture-password", user.salt, user.password_hash))
                self.assertEqual(decrypt_secret((await session.scalar(select(FileSource))).password), "fixture-source")
                game = await session.scalar(select(Game))
                self.assertEqual(Path(game.cover_path).read_bytes(), self.cover.read_bytes())

    @unittest.skipUnless(os.name == "posix", "POSIX permissions")
    async def test_permissions_from_creation_and_atomic_publication(self):
        previous_umask = os.umask(0o022)
        self.addCleanup(os.umask, previous_umask)
        root = Path(self.cfg.data_path) / "backups"
        root.mkdir(mode=0o755)
        managed = backup.backup_dir(self.cfg)
        custom = self.directory / "custom"
        custom.mkdir(mode=0o755)
        for directory in (root, managed):
            self.assertEqual(stat.S_IMODE(directory.stat().st_mode), 0o700)
        for include_media, suffix in [(False, ".json"), (True, ".zip")]:
            output = custom / ("backup" + suffix)
            payload, media = await backup.prepare_backup(self.cfg, "all", include_media)
            backup.write_backup(output, payload, media, include_media=include_media)
            self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)
            with self.assertRaises(OSError):
                with backup.staged_backup(output) as tmp:
                    self.assertEqual(stat.S_IMODE(tmp.stat().st_mode), 0o600)
                    tmp.write_bytes(b"partial")
                    raise OSError("abort")
            self.assertEqual(backup.read_backup_payload(output), payload)
        self.assertEqual(stat.S_IMODE(custom.stat().st_mode), 0o755)
        journal = backup._RestoreJournal.begin(self.cfg)
        settings = self.directory / "settings.json"
        settings.write_text(json.dumps({"old": True}))
        journal.record_file(settings)
        for path in (journal.snapshot, journal.journal_path, journal.backups[str(settings)]):
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        settings.write_text("changed")
        journal.rollback(restore_database=False)
        self.assertEqual(json.loads(settings.read_text()), {"old": True})
        self.assertEqual(stat.S_IMODE(settings.stat().st_mode), 0o644)
