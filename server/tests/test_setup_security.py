import asyncio
import io
import json
import os
import tempfile
import threading
import unittest
import zipfile
from pathlib import Path
from unittest.mock import AsyncMock, patch

from fastapi import HTTPException, UploadFile
from sqlalchemy import select
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

import config
import database
from api import setup
from cli import backup
from cli.common import CliError
from models.user import User
from utils import backup_limits as limits
from utils.process_lock import process_lock


class SetupSecurityTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="sena-setup-security-")
        self.root = Path(self.temp.name).resolve()
        self.cwd = Path.cwd()
        os.chdir(self.root)
        self.config = config.Config(data_path=str(self.root))
        self.engine = create_async_engine(self.config.database_url)
        self.sessions = async_sessionmaker(self.engine, expire_on_commit=False)
        self.patches = [
            patch.object(config, "_cached_config", self.config),
            patch.object(database, "_session_factory", self.sessions),
            patch.object(setup, "_background_scan", new=AsyncMock()),
            patch.object(setup, "hash_password", return_value=("initial-hash", "test-salt")),
        ]
        for item in self.patches:
            item.start()
        async with self.engine.begin() as connection:
            await connection.run_sync(database.Base.metadata.create_all)
        self.payload = {
            "kind": backup.KIND, "schema_version": backup.SCHEMA_VERSION,
            "library": {"games": []},
            "accounts": {"users": [{"username": "winner", "password_hash": "overwritten",
                "salt": "test-salt", "password_set": True, "role": "admin", "status": "active"}]},
        }

    async def asyncTearDown(self):
        if setup._background_tasks:
            await asyncio.gather(*list(setup._background_tasks), return_exceptions=True)
        await self.engine.dispose()
        for item in reversed(self.patches):
            item.stop()
        os.chdir(self.cwd)
        self.assertEqual(self.root, Path(self.temp.name).resolve())
        self.temp.cleanup()

    async def initialize(self, username="winner"):
        async with self.sessions() as session:
            return await setup.initialize_setup(
                setup.InitRequest(admin_username=username, admin_password="password"), session
            )

    def make_archive(self, *, images=False):
        path = self.root / "input.zip"
        payload = dict(self.payload)
        if images:
            payload["media"] = {"covers": [{"key": "abcdefgh.png"}, {"key": "ijklmnop.png"}]}
        with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("backup.json", json.dumps(payload))
            if images:
                archive.writestr("media/covers/abcdefgh.png", b"first image")
                archive.writestr("media/covers/ijklmnop.png", b"second image")
        return path, backup.normalise_payload(payload)

    async def test_late_anonymous_import_cannot_overwrite_initialized_admin(self):
        entered = asyncio.Event()
        release = asyncio.Event()

        class DelayedUpload(UploadFile):
            async def read(inner, size=-1):
                if not entered.is_set():
                    entered.set()
                    await release.wait()
                return await super(DelayedUpload, inner).read(size)

        upload = DelayedUpload(filename="late.json", file=io.BytesIO(json.dumps(self.payload).encode()))
        async with self.sessions() as session:
            task = asyncio.create_task(setup.import_setup_backup(upload, session))
            await asyncio.wait_for(entered.wait(), 2)
            await self.initialize()
            original_settings = (self.root / "config.yaml").read_bytes()
            with patch.object(backup._RestoreJournal, "begin") as journal:
                release.set()
                with self.assertRaises(HTTPException) as rejected:
                    await task
                self.assertEqual(rejected.exception.status_code, 409)
                journal.assert_not_called()
        async with self.sessions() as session:
            users = list((await session.execute(select(User))).scalars())
            self.assertEqual(len(users), 1)
            self.assertEqual(users[0].password_hash, "initial-hash")
        self.assertEqual((self.root / "config.yaml").read_bytes(), original_settings)
        self.assertFalse(list((self.root / "backups").glob("uploaded-*")))
        self.assertFalse(list((self.root / "backups").glob("db-before-*")))

    async def test_concurrent_initializers_share_restore_lock(self):
        entered = asyncio.Event()
        release = asyncio.Event()
        original = setup._initialize_setup_locked

        async def paused(body, session):
            entered.set()
            await release.wait()
            return await original(body, session)

        with patch.object(setup, "_initialize_setup_locked", side_effect=paused):
            first = asyncio.create_task(self.initialize("first"))
            await asyncio.wait_for(entered.wait(), 2)
            try:
                with self.assertRaises(HTTPException) as rejected:
                    await self.initialize("second")
                self.assertEqual(rejected.exception.status_code, 409)
            finally:
                release.set()
                await first
        async with self.sessions() as session:
            self.assertEqual([u.username for u in (await session.execute(select(User))).scalars()], ["first"])

    async def test_cli_or_admin_restore_lock_blocks_anonymous_initialize(self):
        with process_lock(self.root / ".restore.lock") as acquired:
            self.assertTrue(acquired)
            with self.assertRaises(HTTPException) as rejected:
                await self.initialize()
            self.assertEqual(rejected.exception.status_code, 409)
        self.assertTrue((await self.initialize())["admin_created"])

    async def test_restore_rechecks_before_journal_and_media(self):
        await self.initialize()
        path, payload = self.make_archive(images=True)
        with patch.object(backup._RestoreJournal, "begin") as journal:
            with self.assertRaises(backup.SetupAlreadyInitialized):
                await backup.apply_restore(self.config, path, payload,
                    scope=backup.SCOPE_ALL, mode=backup.MODE_MERGE,
                    media_policy=backup.MEDIA_OVERWRITE, require_uninitialized=True)
            journal.assert_not_called()
        self.assertFalse((self.root / "covers").exists())

    async def test_valid_initial_restore_and_normal_admin_restore(self):
        path, payload = self.make_archive(images=True)
        result = await backup.apply_restore(self.config, path, payload,
            scope=backup.SCOPE_ALL, mode=backup.MODE_MERGE,
            media_policy=backup.MEDIA_OVERWRITE, require_uninitialized=True)
        self.assertEqual(result["stats"]["users_new"], 1)
        self.assertEqual((self.root / "covers" / "abcdefgh.png").read_bytes(), b"first image")
        result = await backup.apply_restore(self.config, path, payload,
            scope=backup.SCOPE_ALL, mode=backup.MODE_MERGE,
            media_policy=backup.MEDIA_OVERWRITE)
        self.assertEqual(result["stats"]["users_updated"], 1)

    async def test_low_disk_is_rejected_before_snapshot(self):
        path, payload = self.make_archive()
        with patch.object(limits, "check_restore_space", side_effect=limits.BackupLimitError("no space")):
            with patch.object(backup._RestoreJournal, "begin") as journal:
                with self.assertRaises(CliError):
                    await backup.apply_restore(self.config, path, payload,
                        scope=backup.SCOPE_ALL, mode=backup.MODE_MERGE,
                        media_policy=backup.MEDIA_OVERWRITE)
                journal.assert_not_called()

    async def test_partial_media_failure_is_cleaned_and_database_rolled_back(self):
        await self.initialize()
        path, payload = self.make_archive(images=True)
        original = limits.copy_zip_entry

        def fail_second(archive, name, destination, limit, budget):
            if "ijklmnop" in name:
                destination.write(b"partial")
                raise limits.BackupLimitError("simulated expansion limit")
            return original(archive, name, destination, limit, budget)

        with patch.object(limits, "copy_zip_entry", side_effect=fail_second), patch.object(
            backup, "_restore_database", side_effect=AssertionError("uncommitted DB must not be restored")
        ):
            with self.assertRaises(CliError):
                await backup.apply_restore(self.config, path, payload,
                    scope=backup.SCOPE_ALL, mode=backup.MODE_MERGE,
                    media_policy=backup.MEDIA_OVERWRITE)
        self.assertFalse(list((self.root / "covers").glob("*.png")))
        self.assertFalse((self.root / "backups" / "restore-in-progress.json").exists())
        async with self.sessions() as session:
            user = (await session.execute(select(User))).scalar_one()
            self.assertEqual(user.password_hash, "initial-hash")

    async def test_cancel_waits_for_worker_before_releasing_restore_lock(self):
        entered = asyncio.Event()
        release = threading.Event()
        finished = threading.Event()
        loop = asyncio.get_running_loop()

        def writer():
            loop.call_soon_threadsafe(entered.set)
            release.wait(3)
            finished.set()

        task = asyncio.create_task(backup._restore_thread(writer))
        await asyncio.wait_for(entered.wait(), 2)
        task.cancel()
        await asyncio.sleep(0)
        self.assertFalse(task.done())
        release.set()
        with self.assertRaises(asyncio.CancelledError):
            await task
        self.assertTrue(finished.is_set())
