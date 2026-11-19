import os
import sys
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from cli import common, operations


class UpdateSourceTests(unittest.TestCase):
    def test_channel_and_annotated_commit_resolved_in_one_git_query(self):
        with tempfile.TemporaryDirectory() as tmp:
            def git(*args):
                return subprocess.check_output(["git", "-C", tmp, *args], text=True).strip()

            git("init", "-q", "-b", "main")
            git("-c", "user.name=Test", "-c", "user.email=t@example.invalid",
                "commit", "-qm", "fixture", "--allow-empty")
            sha = git("rev-parse", "HEAD")
            git("tag", "v1.2.0")
            git("tag", "v1.3.0-beta.2")
            latest = "v1.3.0-beta.10"
            git("-c", "user.name=Test", "-c", "user.email=t@example.invalid", "tag", "-am", "beta", latest)
            for channel, expected in (("beta", latest), ("release", "v1.2.0"), ("dev", "main")):
                with self.subTest(channel=channel), patch.object(
                    common.subprocess, "run", wraps=subprocess.run
                ) as run:
                    self.assertEqual(operations.resolve_remote_source(tmp, channel, "main"), (expected, sha, tmp))
                    self.assertEqual(run.call_count, 1)

    def test_unreachable_primary_uses_mirror_before_retrying_with_http(self):
        sha = "b" * 40
        with patch.object(operations, "mirror_candidates", return_value=["mirror"]), patch.object(
            operations, "remote_refs_via_git", side_effect=[None, {"refs/heads/main": sha}]
        ), patch.object(operations, "remote_refs_via_http") as http:
            self.assertEqual(operations.resolve_remote_source("primary", "dev", "main"), ("main", sha, "mirror"))
            http.assert_not_called()


class InstallerUpdateTests(unittest.TestCase):
    script = Path(__file__).resolve().parents[1] / "install.sh"

    def run_shell(self, body, **env):
        # Exercise the shipped functions without running the host installer entry point.
        functions = self.script.read_text().split('\ncase "$ACTION" in\n')[0]
        with tempfile.TemporaryDirectory() as tmp:
            prefix = '''
INSTALL_ROOT="$PWD/install"
DATA_PATH="$PWD/data"
validate_paths
ENV_FILE="$PWD/config.env"
ACTION=update
'''
            return subprocess.run(["bash", "-c", functions + prefix + body], cwd=tmp,
                                  env={**os.environ, **env}, text=True, capture_output=True)

    def test_health_uses_saved_port_without_executing_environment_file(self):
        result = self.run_shell('''
printf '%s\n' 'OTHER=$(touch sourced)' 'SENA_PORT=11111' 'SENA_PORT="23456"' > "$ENV_FILE"
load_service_port
curl() { [[ "${!#}" == http://127.0.0.1:23456/api/health ]]; }
[[ "$PORT_VALUE" == 23456 && ! -e sourced ]]
wait_for_health
''')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_moved_ref_rejected_before_python_setup_or_service_switch(self):
        result = self.run_shell('''
REPO_CACHE_DIR="$PWD/cache"
mkdir -p "$REPO_CACHE_DIR/.git" "$REPO_CACHE_DIR/server"
touch "$REPO_CACHE_DIR/server/requirements.txt"
git_https_helper_ok() { return 0; }
ensure_repo_url() { exit 55; }
run_git_source_fetch() { return 0; }
git() { if [[ "$*" == *rev-parse* ]]; then echo changed; fi; }
remote_server_dir
''', SENA_EXPECTED_SHA="a" * 40)
        self.assertEqual(result.returncode, 1)
        self.assertIn("ref changed after confirmation", result.stderr)

    def test_archive_fallback_uses_confirmed_commit_not_moving_branch(self):
        result = self.run_shell('''
mkdir source
git -C source init -q
touch source/content
git -C source add content
git -C source -c user.name=Test -c user.email=t@example.invalid commit -qm fixture
EXPECTED_SHA=$(git -C source rev-parse HEAD)
git -C source archive --format=tar.gz --prefix=repo/ HEAD > fixture.tar.gz
curl() { [[ " $* " == *"/archive/$EXPECTED_SHA.tar.gz "* ]] && cp fixture.tar.gz "${!#}"; }
remote_ref_sha_via_http() { exit 55; }
fetch_source_via_archive main
[[ $(cat "$REPO_CACHE_DIR/.sena-source-sha") == "$EXPECTED_SHA" ]]
EXPECTED_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
if fetch_source_via_archive main; then exit 10; fi
[[ $(cat "$REPO_CACHE_DIR/.sena-source-sha") != "$EXPECTED_SHA" ]]
''', SENA_PYTHON_BIN=sys.executable)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_code_only_switch_and_rollback_keep_venv(self):
        result = self.run_shell('''
mkdir -p "$APP_DIR" "$VENV_DIR/bin" "$PWD/source"
printf 'before' > "$APP_DIR/revision"
printf 'after' > source/revision
touch "$APP_DIR/requirements.txt" source/requirements.txt
PYTHON_BIN="$PWD/runtime"
cat > "$PYTHON_BIN" <<'SH'
#!/bin/sh
case "$*" in
  *platform.python_version*) echo 3.12.1 ;;
  *'pip --isolated check'*) test ! -e broken ;;
  *'--dry-run --no-index'*|*'import fastapi'*) exit 0 ;;
  *) exit 99 ;;
esac
SH
chmod +x "$PYTHON_BIN"
ln -s "$PYTHON_BIN" "$VENV_DIR/bin/python"
echo 'version = 3.12.1' > "$VENV_DIR/pyvenv.cfg"
inode=$(stat -c %i "$VENV_DIR")
prepare_next_tree "$PWD/source"
[[ "$REUSE_VENV" == true && ! -e "$NEXT_VENV" ]]
touch broken
if can_reuse_venv; then exit 10; fi
rm broken
if SENA_REBUILD_VENV=1 can_reuse_venv; then exit 11; fi
echo dependency >> "$NEXT_SERVER/requirements.txt"
if can_reuse_venv; then exit 12; fi
activate_next_tree
[[ $(cat "$APP_DIR/revision") == after && ! -e "$PREV_VENV" ]]
systemctl() { :; }; write_systemd_service() { :; }; install_cli_command() { :; }
install_control_scripts() { :; }; start_service() { :; }
wait_for_health() { [[ -x "$VENV_DIR/bin/python" && $(cat "$APP_DIR/revision") == before ]]; }
rollback_update
[[ "$inode" == "$(stat -c %i "$VENV_DIR")" ]]
''')
        self.assertEqual(result.returncode, 0, result.stderr)
