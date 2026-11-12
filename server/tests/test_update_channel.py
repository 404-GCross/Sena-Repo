import os
import stat
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from cli import operations
from cli.common import CliError


class UpdateChannelTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="sena-update-channel-")
        self.root = Path(self.temp.name).resolve()
        self.metadata = self.root / ".version"
        self.original = "# keep comment\nSOURCE_SHA=abc123\nSOURCE_URL=https://example.invalid/repo.git\nSOURCE_REF=main\nSOURCE_CHANNEL=dev\nUNKNOWN=value=with=equals\n"
        self.metadata.write_text(self.original)
        self.metadata.chmod(0o640)
        self.patches = [
            patch.dict(os.environ, {"SENA_INSTALL_ROOT": str(self.root)}),
            patch.object(operations, "in_docker", return_value=False),
            patch.object(operations, "channel_ref", return_value="v1.0.0-beta.2"),
            patch.object(operations, "resolve_remote_source", return_value=("abc123", "https://example.invalid/repo.git", [])),
            patch.object(operations, "installer_path", return_value=self.root / "install.sh"),
            patch.object(operations, "run_command", return_value=0),
            patch.object(operations, "confirm", return_value=True),
            patch.object(operations, "echo"),
        ]
        self.mocks = [item.start() for item in self.patches]
        for item in self.patches:
            self.addCleanup(item.stop)
        self.installer = self.mocks[5]
        self.confirm = self.mocks[6]
        self.remote = self.mocks[3]

    def tearDown(self):
        self.assertEqual(self.root, Path(self.temp.name).resolve())
        self.temp.cleanup()

    def args(self, **overrides):
        values = {"repo_url": None, "ref": None, "channel": "beta", "force": False, "yes": True, "check": False}
        values.update(overrides)
        return SimpleNamespace(**values)

    def test_same_sha_persists_only_channel_without_installer(self):
        self.assertEqual(operations.cmd_update(self.args()), 0)
        self.assertEqual(self.metadata.read_text(), self.original.replace("SOURCE_CHANNEL=dev", "SOURCE_CHANNEL=beta"))
        self.assertEqual(stat.S_IMODE(self.metadata.stat().st_mode), 0o640)
        self.installer.assert_not_called()
        self.confirm.assert_not_called()
        self.assertEqual(list(self.root.glob(".version.channel-*")), [])

    def test_whitespace_and_crlf_follow_existing_metadata_reader(self):
        original = b"# keep\r\n SOURCE_SHA = abc123 \r\n SOURCE_CHANNEL = dev \r\nOTHER=yes\r\n"
        self.metadata.write_bytes(original)
        self.assertEqual(operations.cmd_update(self.args()), 0)
        self.assertEqual(self.metadata.read_bytes(), original.replace(b" SOURCE_CHANNEL = dev ", b"SOURCE_CHANNEL=beta"))
        self.installer.assert_not_called()

    def test_missing_channel_and_stable_alias_are_saved(self):
        self.metadata.write_text(self.original.replace("SOURCE_CHANNEL=dev\n", "").rstrip("\n"))
        self.assertEqual(operations.cmd_update(self.args(channel="stable")), 0)
        self.assertIn("SOURCE_CHANNEL=release\n", self.metadata.read_text())
        self.installer.assert_not_called()

    def test_no_selection_same_channel_and_ref_do_not_touch_metadata(self):
        for options in ({"channel": None}, {"channel": "dev"}, {"ref": "custom", "channel": "beta"}):
            with patch.object(operations, "_persist_update_channel") as persist:
                self.assertEqual(operations.cmd_update(self.args(**options)), 0)
                persist.assert_not_called()
            self.assertEqual(self.metadata.read_text(), self.original)
        self.installer.assert_not_called()

    def test_check_is_read_only_even_when_channel_differs(self):
        self.assertEqual(operations.cmd_update(self.args(check=True, yes=False)), 0)
        self.assertEqual(self.metadata.read_text(), self.original)
        self.installer.assert_not_called()
        self.confirm.assert_not_called()

    def test_declined_channel_selection_leaves_old_state(self):
        self.confirm.return_value = False
        self.assertEqual(operations.cmd_update(self.args(yes=False)), 130)
        self.assertEqual(self.metadata.read_text(), self.original)
        self.installer.assert_not_called()

    def test_force_and_new_versions_use_installer_without_prewrite(self):
        for force, remote in ((True, "abc123"), (False, "new-sha")):
            self.remote.return_value = (remote, "https://example.invalid/repo.git", [])
            self.installer.return_value = 17
            self.assertEqual(operations.cmd_update(self.args(force=force)), 17)
            self.assertEqual(self.installer.call_args.kwargs["env"]["SENA_CHANNEL"], "beta")
            self.assertEqual(self.metadata.read_text(), self.original)

    def test_explicit_ref_clears_inherited_channel(self):
        with patch.dict(os.environ, {"SENA_CHANNEL": "beta"}):
            self.assertEqual(operations.cmd_update(self.args(ref="exact-ref", force=True)), 0)
        env = self.installer.call_args.kwargs["env"]
        self.assertEqual(env["SENA_CHANNEL"], "")
        self.assertEqual(env["SENA_REPO_REF"], "exact-ref")

    def test_atomic_replace_failure_leaves_original_and_cleans_temp(self):
        with patch.object(operations.os, "replace", side_effect=PermissionError("fixture")):
            with self.assertRaises(CliError):
                operations.cmd_update(self.args())
        self.assertEqual(self.metadata.read_text(), self.original)
        self.assertEqual(list(self.root.glob(".version.channel-*")), [])
        self.installer.assert_not_called()

    def test_changed_sha_and_symlink_metadata_fail_closed(self):
        with self.assertRaises(CliError):
            operations._persist_update_channel("beta", expected_sha="stale-sha")
        self.assertEqual(self.metadata.read_text(), self.original)
        self.assertEqual(self.metadata.resolve(), self.root / ".version")
        self.metadata.unlink()
        real = self.root / "real-version"
        real.write_text(self.original)
        self.metadata.symlink_to(real)
        with self.assertRaises(CliError):
            operations._persist_update_channel("beta", expected_sha="abc123")
        self.assertEqual(real.read_text(), self.original)

    def test_docker_remains_read_only(self):
        with patch.object(operations, "in_docker", return_value=True):
            self.assertEqual(operations.cmd_update(self.args()), 2)
        self.assertEqual(self.metadata.read_text(), self.original)
        self.installer.assert_not_called()
        self.remote.assert_not_called()


if __name__ == "__main__":
    unittest.main()
