import json
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import AsyncMock, patch

from fastapi import HTTPException
from pydantic import ValidationError

from api import agent, steam_patch
from schemas.agent import AgentSettings
from services.agent.patch_alignment import PatchInventories, copy_candidate


def trees(patch_files, game_files, dirs=()):
    return PatchInventories(
        app_id="42",
        sha256="f" * 64,
        archive_files=patch_files,
        game_files=game_files,
        game_dirs=list(dirs),
    )


class AlignmentTests(unittest.TestCase):
    def test_unique_alignment_carries_new_files(self):
        data = trees(
            ["release/a.bin", "release/b.bin", "release/new.bin"],
            ["assets/a.bin", "assets/b.bin"],
        )
        rule = copy_candidate(data)
        self.assertEqual((rule["patch_dir"], rule["target_dir"]), ("release", "assets"))

    def test_unambiguous_named_resource_directory(self):
        rule = copy_candidate(
            trees(
                ["Sample_Data/new.asset", "README.txt"], ["game.exe"], ["Sample_Data"]
            )
        )
        self.assertEqual((rule["patch_dir"], rule["target_dir"]), ("", ""))

    def test_refuse_conflicts_generic_paths_and_installers(self):
        for data in [
            trees(["patch.xp3"], ["patch.xp3"]),
            trees(["a", "b", "c", "d"], ["A/a", "A/b", "B/c", "B/d"]),
            trees(["a", "b", "setup.exe"], ["a", "b"]),
            trees(["a", "b"], ["A/a", "B/a", "A/b", "B/b"]),
        ]:
            self.assertIsNone(copy_candidate(data))
        with self.assertRaises(ValidationError):
            trees(["../bad"], ["a"])


class ConfigureTests(unittest.IsolatedAsyncioTestCase):
    async def test_save_only_approved_and_never_replace_existing_rules(self):
        with tempfile.TemporaryDirectory() as tmp:
            index = Path(tmp)
            path = index / "patches.json"
            row = {"file": "archive.zip", "app_id": 42, "source_type": "openlist"}
            path.write_text(json.dumps({"patches": [row]}))
            key = steam_patch._make_patch_id(row)
            body = trees(["wrapper/a", "wrapper/b"], ["data/a", "data/b"])
            model = AsyncMock(
                return_value=(
                    {"calls": [{"name": "review", "arguments": {"approve": False}}]},
                    100,
                )
            )
            with (
                patch.object(steam_patch, "_get_patch_index_dir", return_value=index),
                patch.object(
                    agent,
                    "load_settings",
                    new=AsyncMock(
                        return_value=(AgentSettings(enabled=True, model="test"), 1)
                    ),
                ),
                patch.object(agent.ModelClient, "turn", model),
            ):
                self.assertEqual(
                    (await agent.configure_local_patch(key, body, None))["status"],
                    "pending",
                )
                self.assertEqual(json.loads(path.read_text())["patches"], [row])
                model.return_value[0]["calls"][0]["arguments"]["approve"] = True
                self.assertEqual(
                    (await agent.configure_local_patch(key, body, None))["status"],
                    "confirmed",
                )
                saved = json.loads(path.read_text())["patches"][0]
                self.assertEqual(saved["manifest_sha256"], body.sha256)
                self.assertEqual(saved["target_dir"], "data")
                with self.assertRaises(HTTPException):
                    await agent.configure_local_patch(key, body, None)
                self.assertEqual(model.await_count, 2)

    async def test_local_patch_reads_the_server_file_without_a_client_archive(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            archive = root / "sample.zip"
            with zipfile.ZipFile(archive, "w") as zf:
                zf.writestr("wrapper/sample-a.bin", b"a")
                zf.writestr("wrapper/sample-b.bin", b"b")
            row = {"file": str(archive), "app_id": 42, "source_type": "local"}
            path = root / "patches.json"
            path.write_text(json.dumps({"patches": [row]}))
            body = PatchInventories(
                app_id="42",
                game_files=["data/sample-a.bin", "data/sample-b.bin"],
                game_dirs=["data"],
            )
            with (
                patch.object(steam_patch, "_get_patch_index_dir", return_value=root),
                patch.object(steam_patch, "_get_patches_dir", return_value=root),
                patch.object(
                    steam_patch, "_patch_roots", new=AsyncMock(return_value=[])
                ),
                patch.object(
                    agent,
                    "load_settings",
                    new=AsyncMock(
                        return_value=(AgentSettings(enabled=True, model="test"), 1)
                    ),
                ),
                patch.object(
                    agent.ModelClient,
                    "turn",
                    new=AsyncMock(
                        return_value=(
                            {
                                "calls": [
                                    {"name": "review", "arguments": {"approve": True}}
                                ]
                            },
                            42,
                        )
                    ),
                ),
            ):
                result = await agent.configure_local_patch(
                    steam_patch._make_patch_id(row), body, None
                )
            self.assertEqual(
                (result["patch_dir"], result["target_dir"]), ("wrapper", "data")
            )
            self.assertEqual(
                len(json.loads(path.read_text())["patches"][0]["manifest_sha256"]), 64
            )
