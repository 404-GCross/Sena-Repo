import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from cli import operations, versions


class VersionDisplayTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="sena-version-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.sha = "a" * 40
        env = patch.dict(os.environ, {"SENA_VERSION": ""})
        env.start()
        self.addCleanup(env.stop)

    def test_published_versions_keep_release_tags(self):
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
            versions.source_version("v1.0.0-beta.3", self.sha), "v1.0.0-beta.3"
        )
        self.assertEqual(versions.source_version("v1.0.0", self.sha), "v1.0.0")

    def test_development_build_does_not_use_release_baseline(self):
        metadata = {
            "SOURCE_VERSION": "1.0.0-beta.3",
            "SOURCE_REF": "main",
            "SOURCE_SHA": self.sha,
            "SOURCE_CHANNEL": "dev",
        }
        self.assertEqual(versions.installed_version(metadata), "dev-aaaaaaa")
        self.assertEqual(versions.source_version("main", "b" * 40), "dev-bbbbbbb")
        self.assertEqual(
            versions.source_version("dev-release", self.sha), "dev-aaaaaaa"
        )
        self.assertEqual(
            versions.source_version("feature/custom", self.sha), "dev-aaaaaaa"
        )

    def test_runtime_version_takes_precedence(self):
        metadata = {
            "SOURCE_VERSION": "1.0.0-beta.3",
            "SOURCE_REF": "main",
            "SOURCE_SHA": self.sha,
        }
        for reported, expected in (
            ("dev-2fc6d28", "dev-2fc6d28"),
            ("dev", "dev"),
            ("test", "test"),
            ("1.0.0-beta.3", "v1.0.0-beta.3"),
            ("v1.0.0", "v1.0.0"),
        ):
            with patch.dict(os.environ, {"SENA_VERSION": reported}):
                self.assertEqual(versions.installed_version(metadata), expected)
                self.assertEqual(operations._reported_version(metadata), expected)

    def test_switching_future_channel_does_not_relabel_installed_build(self):
        metadata = {
            "SOURCE_SHA": self.sha,
            "SOURCE_REF": "main",
            "SOURCE_CHANNEL": "beta",
        }
        self.assertEqual(versions.installed_version(metadata), "dev-aaaaaaa")
        metadata.update(SOURCE_REF="v1.0.0-beta.3", SOURCE_CHANNEL="dev")
        self.assertEqual(versions.installed_version(metadata), "v1.0.0-beta.3")

    def test_missing_or_invalid_build_is_not_replaced_with_baseline(self):
        with patch.dict(os.environ, {"SENA_VERSION": "<html>not-a-version</html>"}):
            self.assertEqual(
                versions.installed_version({"SOURCE_VERSION": "1.0.0-beta.3"}), "未知"
            )
            self.assertEqual(versions.source_version("main", "--not-a-sha"), "未知")
            self.assertEqual(
                versions.source_version("vfeature", self.sha), "dev-aaaaaaa"
            )

    def run_update(self, metadata, remote_sha, ref="main", check=False):
        args = SimpleNamespace(
            repo_url=None, ref=None, channel=None, force=False, yes=False, check=check
        )
        with (
            patch.object(operations, "in_docker", return_value=False),
            patch.object(operations, "read_version_metadata", return_value=metadata),
            patch.object(operations, "channel_ref", return_value=ref),
            patch.object(
                operations,
                "resolve_remote_source",
                return_value=(remote_sha, "https://github.com/owner/repo.git", []),
            ),
            patch.object(
                operations, "installer_path", return_value=self.root / "install.sh"
            ),
            patch.object(operations, "run_command", return_value=0) as install,
            patch.object(operations, "echo") as echo,
            patch.object(operations, "confirm", return_value=True) as confirm,
            patch(
                "urllib.request.urlopen",
                side_effect=AssertionError("Do not fetch VERSION to label a build"),
            ),
        ):
            result = operations.cmd_update(args)
            return (
                result,
                [c.args[0] for c in echo.call_args_list],
                install.call_count,
                confirm.call_args,
            )

    def test_update_shows_dev_versions_channel_and_separate_commits(self):
        metadata = {
            "SOURCE_SHA": self.sha,
            "SOURCE_VERSION": "1.0.0-beta.3",
            "SOURCE_REF": "main",
            "SOURCE_CHANNEL": "dev",
        }
        result, lines, installed, confirmation = self.run_update(metadata, "b" * 40)
        self.assertEqual(result, 0)
        self.assertIn("当前版本: dev-aaaaaaa", lines)
        self.assertIn("目标版本: dev-bbbbbbb", lines)
        self.assertIn("更新通道: dev / main", lines)
        self.assertIn("当前提交: aaaaaaaaaaaa", lines)
        self.assertIn("目标提交: bbbbbbbbbbbb", lines)
        self.assertIn("dev-bbbbbbb", confirmation.args[0])
        self.assertNotIn("beta.3", "\n".join(lines))
        self.assertEqual(installed, 1)

    def test_release_target_is_distinct_from_current_dev_version(self):
        metadata = {
            "SOURCE_SHA": self.sha,
            "SOURCE_REF": "main",
            "SOURCE_CHANNEL": "beta",
        }
        result, lines, installed, _ = self.run_update(
            metadata, "b" * 40, ref="v1.0.0-beta.3"
        )
        self.assertEqual(result, 0)
        self.assertIn("当前版本: dev-aaaaaaa", lines)
        self.assertIn("目标版本: v1.0.0-beta.3", lines)
        self.assertEqual(installed, 1)

    def test_full_sha_not_display_version_controls_update_detection(self):
        metadata = {
            "SOURCE_SHA": "abcdef0" + "a" * 33,
            "SOURCE_REF": "main",
            "SOURCE_CHANNEL": "dev",
        }
        result, lines, installed, _ = self.run_update(
            metadata, "abcdef0" + "b" * 33, check=True
        )
        self.assertEqual(result, 1)
        self.assertIn("当前版本: dev-abcdef0", lines)
        self.assertIn("目标版本: dev-abcdef0", lines)
        self.assertEqual(installed, 0)

    def test_installer_records_project_baseline_for_archive_sources(self):
        script = (Path(__file__).resolve().parents[1] / "install.sh").read_text()
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

    def test_detached_cache_checkout_remains_quiet(self):
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
        result = git(
            "-c", "advice.detachedHead=false", "checkout", "--quiet", "--force", first
        )
        self.assertEqual(result.stdout + result.stderr, "")
        (cache / "VERSION").write_text("1.0.0-beta.3\n")
        git("add", "VERSION")
        git("commit", "-qm", "test: create detached fixture")
        result = git(
            "-c", "advice.detachedHead=false", "checkout", "--quiet", "--force", first
        )
        self.assertEqual(result.stdout + result.stderr, "")
