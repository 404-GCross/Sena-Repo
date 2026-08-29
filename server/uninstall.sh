#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
INSTALLER="$SCRIPT_DIR/install.sh"

if [ ! -f "$INSTALLER" ]; then
  printf '[sena-repo] ERROR: install.sh was not found next to uninstall.sh\n' >&2
  exit 1
fi

exec bash "$INSTALLER" --uninstall "$@"
