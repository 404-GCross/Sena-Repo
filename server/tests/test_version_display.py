import contextlib
import os
import subprocess
import tempfile
import unittest
from io import BytesIO
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from cli import operations, versions


class VersionDisplayTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="sena-version-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.server = self.root / "server"
        self.server.mkdir()
        self.sha = "a" * 40
        for mock in (
            patch.object(versions, "install_root", return_value=self.root),
            patch.object(versions, "SERVER_DIR", self.server),
            patch.dict(os.environ, {"SENA_VERSION": ""}),
        ):
            mock.start()
            self.addCleanup(mock.stop)

    def test_version_validation_and_channel_labels(self):
        for value in ("1.0.0-beta.3", "v1.0.0", "1.0.0+build.123"):
            self.assertEqual(versions.project_version(value), value.removeprefix("v"))
        for value in (
            "dev-abc1234",
            "<html>bad</html>",
            "1.0.0\nFAKE=value",
            "1.0.0-beta..3",
            "\x1b[31m1.0.0",
        ):
            self.assertEqual(versions.project_version(value), "")
        self.assertEqual(
            versions.version_label("1.0.0-beta.3", "main"), "v1.0.0-beta.3（开发版）"
        )
        self.assertEqual(
            versions.version_label("1.0.0-beta.3", "v1.0.0-beta.3"),
            "v1.0.0-beta.3（测试版）",
        )
        self.assertEqual(versions.version_label("1.0.0", "1.0.0"), "v1.0.0（正式版）")
        self.assertIn("未知", versions.version_label("", "main"))

    def test_installed_version_prefers_recorded_metadata_not_cache_head(self):
        (self.server / "VERSION").write_text("9.9.9")
        self.assertEqual(
            versions.installed_project_version(
                {"SOURCE_VERSION": "1.0.0-beta.3", "SOURCE_REF": "main"}
            ),
            "1.0.0-beta.3",
        )
        (self.server / "VERSION").unlink()
        with patch.object(
            versions, "_cached_version", return_value="1.0.0-beta.1"
        ) as cached:
            version = versions.installed_project_version(
                {"SOURCE_SHA": self.sha, "SOURCE_REF": "main"}
            )
        self.assertEqual(version, "1.0.0-beta.1")
        cached.assert_called_once_with(self.sha)

    def test_staged_version_and_release_tag_work_offline(self):
        (self.server / "VERSION").write_text("1.0.0-beta.3\n")
        with patch.object(versions.urllib.request, "urlopen") as network:
            self.assertEqual(
                versions.installed_project_version({"SOURCE_REF": "main"}),
                "1.0.0-beta.3",
            )
            self.assertEqual(
                versions.remote_project_version(
                    "https://example.invalid/repo.git", self.sha, "v1.0.0-beta.2"
                ),
                "1.0.0-beta.2",
            )
            network.assert_not_called()

    def test_remote_lookup_uses_resolved_sha_and_supports_mirror(self):
        with patch.object(
            versions.urllib.request,
            "urlopen",
            return_value=contextlib.closing(BytesIO(b"1.0.0-beta.3\n")),
        ) as network:
            value = versions.remote_project_version(
                "https://mirror.invalid/https://github.com/owner/repo.git",
                self.sha,
                "main",
            )
        self.assertEqual(value, "1.0.0-beta.3")
        self.assertEqual(
            network.call_args.args[0].full_url,
            f"https://mirror.invalid/https://raw.githubusercontent.com/owner/repo/{self.sha}/VERSION",
        )
        self.assertNotIn("/main/", network.call_args.args[0].full_url)

    def test_remote_errors_do_not_block_update(self):
        with patch.object(
            versions.urllib.request, "urlopen", side_effect=OSError("offline")
        ):
            self.assertEqual(
                versions.remote_project_version(
                    "https://github.com/owner/repo.git", self.sha, "main"
                ),
                "",
            )
        with patch.object(versions.urllib.request, "urlopen") as network:
            self.assertEqual(
                versions.remote_project_version(
                    "https://github.com/owner/repo.git", "--not-a-sha"
                ),
                "",
            )
            network.assert_not_called()

    def test_same_project_version_different_commit_is_still_an_update(self):
        args = SimpleNamespace(
            repo_url=None, ref=None, channel=None, force=False, yes=False, check=False
        )
        metadata = {
            "SOURCE_SHA": "a" * 40,
            "SOURCE_REF": "main",
            "SOURCE_CHANNEL": "dev",
            "SOURCE_URL": "https://github.com/owner/repo.git",
        }
        with (
            patch.object(operations, "in_docker", return_value=False),
            patch.object(operations, "read_version_metadata", return_value=metadata),
            patch.object(operations, "channel_ref", return_value="main"),
            patch.object(
                operations,
                "resolve_remote_source",
                return_value=("b" * 40, metadata["SOURCE_URL"], []),
            ),
            patch.object(
                operations, "installed_project_version", return_value="1.0.0-beta.3"
            ),
            patch.object(
                operations, "remote_project_version", return_value="1.0.0-beta.3"
            ),
            patch.object(
                operations, "installer_path", return_value=self.root / "install.sh"
            ),
            patch.object(operations, "run_command", return_value=0) as install,
            patch.object(operations, "echo") as echo,
            patch.object(operations, "confirm", return_value=True) as confirm,
        ):
            self.assertEqual(operations.cmd_update(args), 0)
            lines = [call.args[0] for call in echo.call_args_list]
            self.assertIn("当前版本: v1.0.0-beta.3（开发版）", lines)
            self.assertIn("目标版本: v1.0.0-beta.3（开发版）", lines)
            self.assertIn("目标提交: bbbbbbbbbbbb", lines)
            self.assertIn("v1.0.0-beta.3", confirm.call_args.args[0])
            install.assert_called_once()

    def test_installer_records_project_version_for_archive_sources(self):
        source = Path(__file__).resolve().parents[1] / "install.sh"
        script = source.read_text()
        functions = []
        for name in ("source_project_version", "write_version_metadata"):
            start = script.index(name + "() {")
            end = script.index("\n}\n", start) + 3
            functions.append(script[start:end])
        parent = self.root / "archive"
        server = parent / "server"
        server.mkdir(parents=True)
        (parent / "VERSION").write_text("1.0.0-beta.3\n")
        (parent / ".sena-source-sha").write_text(self.sha)
        metadata = self.root / ".version"
        command = (
            "\n".join(functions)
            + "\n"
            + """
set -eu
git() { return 1; }
source_dir="$1"
REPO_CACHE_DIR="$2"
VERSION_FILE="$3"
REPO_URL=https://github.com/owner/repo.git
REPO_REF=main
PERSIST_CHANNEL=dev
write_version_metadata "$source_dir"
"""
        )
        subprocess.run(
            ["bash", "-c", command, "test", str(server), str(parent), str(metadata)],
            check=True,
            capture_output=True,
        )
        self.assertIn("SOURCE_VERSION=1.0.0-beta.3\n", metadata.read_text())
        self.assertIn(f"SOURCE_SHA={self.sha}\n", metadata.read_text())

    def test_git_version_lookup_is_pinned_and_checkout_is_quiet(self):
        cache = self.root / "repo"
        cache.mkdir()

        def git(*args):
            return subprocess.run(
                ["git", "-C", str(cache), *args],
                check=True,
                capture_output=True,
                text=True,
            )

        git("init", "-q")
        git("config", "user.name", "Version test")
        git("config", "user.email", "test@example.invalid")
        (cache / "VERSION").write_text("1.0.0-beta.1\n")
        git("add", "VERSION")
        git("commit", "-qm", "test: create fixture")
        first = git("rev-parse", "HEAD").stdout.strip()
        (cache / "VERSION").write_text("1.0.0-beta.3\n")
        git("add", "VERSION")
        git("commit", "-qm", "test: update fixture")
        second = git("rev-parse", "HEAD").stdout.strip()
        self.assertEqual(versions._cached_version(first), "1.0.0-beta.1")
        result = git(
            "-c", "advice.detachedHead=false", "checkout", "--quiet", "--force", first
        )
        self.assertEqual(result.stdout + result.stderr, "")
        (cache / "VERSION").write_text("1.0.0-beta.2\n")
        git("add", "VERSION")
        git("commit", "-qm", "test: create detached fixture")
        result = git(
            "-c", "advice.detachedHead=false", "checkout", "--quiet", "--force", second
        )
        self.assertEqual(result.stdout + result.stderr, "")
