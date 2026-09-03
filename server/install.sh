#!/usr/bin/env bash
set -Eeuo pipefail

SERVICE_NAME="sena-repo"
DEFAULT_REPO_URL="https://github.com/404-GCross/Sena-Repo.git"
DEFAULT_REPO_REF="dev"

ACTION="install"
DATA_ACTION="ask"
REQUESTED_DATA_PATH="${SENA_DATA_PATH:-}"
REQUESTED_REPO_URL="${SENA_REPO_URL:-}"
REQUESTED_REPO_REF="${SENA_REPO_REF:-}"
CHECK_ONLY="false"
for arg in "$@"; do
  case "$arg" in
    --install)
      ACTION="install"
      ;;
    --update)
      ACTION="update"
      ;;
    --check)
      CHECK_ONLY="true"
      ;;
    --uninstall)
      ACTION="uninstall"
      ;;
    --purge-data)
      [ "$DATA_ACTION" != "keep" ] || {
        printf '[sena-repo] ERROR: --keep-data and --purge-data cannot be used together\n' >&2
        exit 2
      }
      DATA_ACTION="purge"
      ;;
    --keep-data)
      [ "$DATA_ACTION" != "purge" ] || {
        printf '[sena-repo] ERROR: --keep-data and --purge-data cannot be used together\n' >&2
        exit 2
      }
      DATA_ACTION="keep"
      ;;
    -h|--help)
      cat <<'EOF'
Sena Repo server bare-metal installer.

Usage:
  sudo bash server/install.sh
  sudo bash server/install.sh --update
  sudo bash server/install.sh --check
  sudo bash server/install.sh --uninstall [--keep-data|--purge-data]

Update behavior:
  --update      Fetch the latest source from SENA_REPO_URL/SENA_REPO_REF,
                keep existing data and configuration, then restart the service.
  --check       Check the remote source revision without installing or updating.

Environment overrides:
  SENA_INSTALL_ROOT=/opt/sena-repo
  SENA_DATA_PATH=/var/lib/sena-repo
  SENA_GAMES_PATH=/srv/sena-repo/games
  SENA_PATCH_DIR=/srv/sena-repo/steam_patch
  SENA_HOST=0.0.0.0
  SENA_PORT=11451
  SENA_REPO_URL=https://github.com/404-GCross/Sena-Repo.git
  SENA_REPO_REF=dev
  SENA_HIKARINAGI_CLIENT_ID=...
  SENA_HIKARINAGI_CLIENT_SECRET=...
  SENA_HIKARINAGI_SCOPE=catalog:full

Uninstall data options:
  --keep-data   Keep the database, generated data, and server configuration.
  --purge-data  Remove the database, generated data, and server configuration.
  If neither is provided, the script asks when an interactive terminal is available.
EOF
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

INSTALL_ROOT="${SENA_INSTALL_ROOT:-/opt/sena-repo}"
APP_DIR="$INSTALL_ROOT/server"
VENV_DIR="$INSTALL_ROOT/venv"
REPO_CACHE_DIR="$INSTALL_ROOT/repo"
CONTROL_INSTALLER="$INSTALL_ROOT/install.sh"
CONTROL_UNINSTALLER="$INSTALL_ROOT/uninstall.sh"
VERSION_FILE="$INSTALL_ROOT/.version"
ENV_DIR="/etc/sena-repo"
ENV_FILE="$ENV_DIR/sena-repo.env"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME.service"
DATA_PATH="${SENA_DATA_PATH:-/var/lib/sena-repo}"
GAMES_PATH="${SENA_GAMES_PATH:-/srv/sena-repo/games}"
PATCH_DIR="${SENA_PATCH_DIR:-/srv/sena-repo/steam_patch}"
HOST_VALUE="${SENA_HOST:-0.0.0.0}"
PORT_VALUE="${SENA_PORT:-11451}"
REPO_URL="${SENA_REPO_URL:-$DEFAULT_REPO_URL}"
REPO_REF="${SENA_REPO_REF:-$DEFAULT_REPO_REF}"
HIKARINAGI_CLIENT_ID="${SENA_HIKARINAGI_CLIENT_ID:-}"
HIKARINAGI_CLIENT_SECRET="${SENA_HIKARINAGI_CLIENT_SECRET:-}"
HIKARINAGI_SCOPE="${SENA_HIKARINAGI_SCOPE:-}"

TEMP_DIR=""

log() {
  printf '[sena-repo] %s\n' "$*" >&2
}

die() {
  printf '[sena-repo] ERROR: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
    rm -rf "$TEMP_DIR"
  fi
}
trap cleanup EXIT

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "please run this installer as root, for example: sudo bash server/install.sh"
  fi
}

require_systemd() {
  command -v systemctl >/dev/null 2>&1 || die "systemctl not found; this installer currently requires systemd"
  [ -d /run/systemd/system ] || die "systemd is not running; this installer currently requires systemd"
}

validate_paths() {
  local normalized_install_root normalized_data_path
  case "$INSTALL_ROOT" in
    /*) ;;
    *) die "SENA_INSTALL_ROOT must be an absolute path: $INSTALL_ROOT" ;;
  esac
  case "$DATA_PATH" in
    /*) ;;
    *) die "SENA_DATA_PATH must be an absolute path: $DATA_PATH" ;;
  esac

  normalized_install_root="$(realpath -m -- "$INSTALL_ROOT")"
  normalized_data_path="$(realpath -m -- "$DATA_PATH")"
  case "$normalized_install_root" in
    ""|"/"|"/opt"|"/usr"|"/usr/local"|"/var"|"/srv"|"/etc")
      die "unsafe SENA_INSTALL_ROOT: $INSTALL_ROOT"
      ;;
  esac
  case "$normalized_data_path" in
    ""|"/"|"/opt"|"/usr"|"/usr/local"|"/var"|"/srv"|"/etc")
      die "unsafe SENA_DATA_PATH: $DATA_PATH"
      ;;
  esac

  INSTALL_ROOT="$normalized_install_root"
  DATA_PATH="$normalized_data_path"
  APP_DIR="$INSTALL_ROOT/server"
  VENV_DIR="$INSTALL_ROOT/venv"
  REPO_CACHE_DIR="$INSTALL_ROOT/repo"
  CONTROL_INSTALLER="$INSTALL_ROOT/install.sh"
  CONTROL_UNINSTALLER="$INSTALL_ROOT/uninstall.sh"
  VERSION_FILE="$INSTALL_ROOT/.version"
}

data_exists() {
  [ -d "$DATA_PATH" ] || [ -f "$DATA_PATH" ] || [ -d "$ENV_DIR" ] || [ -f "$ENV_FILE" ]
}

load_existing_data_path() {
  local saved_data_path
  if [ -n "$REQUESTED_DATA_PATH" ] || [ ! -f "$ENV_FILE" ]; then
    return
  fi
  saved_data_path="$(sed -n 's/^SENA_DATA_PATH=//p' "$ENV_FILE" | head -n 1)"
  if [ -n "$saved_data_path" ]; then
    DATA_PATH="$saved_data_path"
  fi
}

load_existing_source_config() {
  local saved_repo_url saved_repo_ref
  if [ -n "$REQUESTED_REPO_URL" ] || [ -n "$REQUESTED_REPO_REF" ] || [ ! -f "$VERSION_FILE" ]; then
    return
  fi
  saved_repo_url="$(sed -n 's/^SOURCE_URL=//p' "$VERSION_FILE" | head -n 1)"
  saved_repo_ref="$(sed -n 's/^SOURCE_REF=//p' "$VERSION_FILE" | head -n 1)"
  if [ -n "$saved_repo_url" ]; then
    REPO_URL="$saved_repo_url"
  fi
  if [ -n "$saved_repo_ref" ]; then
    REPO_REF="$saved_repo_ref"
  fi
}

deployment_exists() {
  [ -e "$APP_DIR" ] || [ -e "$VENV_DIR" ] || [ -e "$SERVICE_FILE" ] || [ -f "$VERSION_FILE" ]
}

installed_source_sha() {
  [ -f "$VERSION_FILE" ] || return 0
  sed -n 's/^SOURCE_SHA=//p' "$VERSION_FILE" | head -n 1
}

remote_source_sha() {
  command -v git >/dev/null 2>&1 || return 1
  git ls-remote "$REPO_URL" "$REPO_REF" 2>/dev/null | awk 'NR == 1 { print $1; exit }'
}

check_remote_update() {
  local current_sha remote_sha
  current_sha="$(installed_source_sha)"
  if [ -z "$current_sha" ]; then
    log "installed source revision is unknown; update is required to record it"
    return 1
  fi

  remote_sha="$(remote_source_sha || true)"
  if [ -z "$remote_sha" ]; then
    log "unable to check the remote source revision"
    return 2
  fi
  if [ "$current_sha" = "$remote_sha" ]; then
    log "Sena Repo server is already up to date ($current_sha)"
    return 0
  fi

  log "update available: $current_sha -> $remote_sha"
  return 1
}

check_installation() {
  require_root
  load_existing_source_config
  validate_paths
  if ! deployment_exists; then
    log "Sena Repo server is not installed at $INSTALL_ROOT"
    log "run install.sh without --check to install it"
    return 1
  fi

  local check_status=0
  check_remote_update || check_status=$?
  case "$check_status" in
    0|1)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

detect_arch() {
  local machine
  machine="$(uname -m)"
  case "$machine" in
    x86_64|amd64)
      log "detected architecture: amd64"
      ;;
    aarch64|arm64)
      log "detected architecture: arm64"
      ;;
    armv7l|armv7*|armhf)
      log "detected architecture: arm32; using bare-metal Python deployment"
      ;;
    armv6l|armv6*)
      log "detected architecture: armv6; install will try, but this is not officially supported"
      ;;
    *)
      log "detected architecture: $machine; install will try, but this is not officially supported"
      ;;
  esac
}

install_system_dependencies() {
  if ! command -v apt-get >/dev/null 2>&1; then
    die "apt-get not found; currently supported bare-metal installer targets Debian/Ubuntu/Armbian"
  fi

  log "installing system dependencies"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    python3 \
    python3-venv \
    python3-pip \
    python3-dev \
    build-essential \
    pkg-config \
    libffi-dev \
    libssl-dev \
    libxml2-dev \
    libxslt1-dev \
    zlib1g-dev \
    p7zip-full
}

local_server_dir() {
  local script_dir
  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P || true)"
  if [ -n "$script_dir" ] && [ -f "$script_dir/requirements.txt" ] && [ -f "$script_dir/main.py" ]; then
    printf '%s\n' "$script_dir"
    return 0
  fi
  return 1
}

remote_server_dir() {
  mkdir -p "$INSTALL_ROOT"
  if [ -d "$REPO_CACHE_DIR/.git" ]; then
    log "updating cached source from $REPO_URL ($REPO_REF)"
    git -C "$REPO_CACHE_DIR" remote set-url origin "$REPO_URL"
    git -C "$REPO_CACHE_DIR" fetch --depth 1 origin "$REPO_REF"
    git -C "$REPO_CACHE_DIR" checkout --force FETCH_HEAD
  else
    rm -rf "$REPO_CACHE_DIR"
    log "cloning source from $REPO_URL ($REPO_REF)"
    git clone --depth 1 --branch "$REPO_REF" "$REPO_URL" "$REPO_CACHE_DIR"
  fi

  [ -f "$REPO_CACHE_DIR/server/requirements.txt" ] || die "server requirements not found in cloned repository"
  printf '%s\n' "$REPO_CACHE_DIR/server"
}

resolve_source_server_dir() {
  if [ "$ACTION" = "update" ]; then
    log "update requested; ignoring local source tree and fetching the latest remote source"
    remote_server_dir
  elif local_server_dir >/dev/null 2>&1; then
    local_server_dir
  else
    remote_server_dir
  fi
}

stop_service_if_exists() {
  if systemctl list-unit-files "$SERVICE_NAME.service" >/dev/null 2>&1; then
    systemctl stop "$SERVICE_NAME.service" >/dev/null 2>&1 || true
  fi
}

copy_server_files() {
  local source_dir="$1"
  local next_dir="$INSTALL_ROOT/server.next"

  log "installing server files to $APP_DIR"
  mkdir -p "$INSTALL_ROOT"
  rm -rf "$next_dir"
  mkdir -p "$next_dir"
  cp -a "$source_dir/." "$next_dir/"
  rm -rf "$APP_DIR"
  mv "$next_dir" "$APP_DIR"
}

install_control_scripts() {
  log "installing persistent control scripts to $INSTALL_ROOT"
  cp "$APP_DIR/install.sh" "$CONTROL_INSTALLER"
  cp "$APP_DIR/uninstall.sh" "$CONTROL_UNINSTALLER"
  chmod 0755 "$CONTROL_INSTALLER" "$CONTROL_UNINSTALLER"
}

write_version_metadata() {
  local source_dir="$1"
  local source_sha metadata_tmp
  source_sha="$(git -C "$source_dir" rev-parse HEAD 2>/dev/null || true)"
  [ -n "$source_sha" ] || return 0

  metadata_tmp="$VERSION_FILE.tmp"
  umask 022
  {
    printf 'SOURCE_SHA=%s\n' "$source_sha"
    printf 'SOURCE_URL=%s\n' "$REPO_URL"
    printf 'SOURCE_REF=%s\n' "$REPO_REF"
  } > "$metadata_tmp"
  mv -f -- "$metadata_tmp" "$VERSION_FILE"
}

write_environment_file() {
  mkdir -p "$ENV_DIR" "$DATA_PATH" "$GAMES_PATH" "$PATCH_DIR"

  if [ -f "$ENV_FILE" ]; then
    log "keeping existing environment file: $ENV_FILE"
    return
  fi

  log "writing environment file: $ENV_FILE"
  umask 077
  {
    printf 'SENA_HOST=%s\n' "$HOST_VALUE"
    printf 'SENA_PORT=%s\n' "$PORT_VALUE"
    printf 'SENA_DATA_PATH=%s\n' "$DATA_PATH"
    printf 'SENA_GAMES_PATH=%s\n' "$GAMES_PATH"
    printf 'SENA_PATCH_DIR=%s\n' "$PATCH_DIR"
    if [ -n "$HIKARINAGI_CLIENT_ID" ]; then
      printf 'SENA_HIKARINAGI_CLIENT_ID=%s\n' "$HIKARINAGI_CLIENT_ID"
    fi
    if [ -n "$HIKARINAGI_CLIENT_SECRET" ]; then
      printf 'SENA_HIKARINAGI_CLIENT_SECRET=%s\n' "$HIKARINAGI_CLIENT_SECRET"
    fi
    if [ -n "$HIKARINAGI_SCOPE" ]; then
      printf 'SENA_HIKARINAGI_SCOPE=%s\n' "$HIKARINAGI_SCOPE"
    fi
  } > "$ENV_FILE"
}

install_python_dependencies() {
  log "installing Python dependencies"
  python3 -m venv "$VENV_DIR"
  "$VENV_DIR/bin/python" -m pip install --upgrade pip setuptools wheel
  "$VENV_DIR/bin/python" -m pip install -r "$APP_DIR/requirements.txt"
}

write_systemd_service() {
  log "writing systemd service: $SERVICE_FILE"
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Sena Repo Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$APP_DIR
EnvironmentFile=$ENV_FILE
ExecStart=$VENV_DIR/bin/python -m uvicorn main:app --host \${SENA_HOST} --port \${SENA_PORT} --loop asyncio
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
}

start_service() {
  log "starting $SERVICE_NAME"
  systemctl daemon-reload
  systemctl enable --now "$SERVICE_NAME.service"
  systemctl --no-pager --full status "$SERVICE_NAME.service" || true
}

install_or_update() {
  local source_dir
  require_root
  require_systemd
  load_existing_source_config
  validate_paths
  detect_arch
  install_system_dependencies
  source_dir="$(resolve_source_server_dir)"
  if [ "$ACTION" = "update" ]; then
    log "updating Sena Repo server from $REPO_URL ($REPO_REF)"
  else
    log "installing Sena Repo server"
  fi
  stop_service_if_exists
  copy_server_files "$source_dir"
  install_control_scripts
  write_environment_file
  install_python_dependencies
  write_systemd_service
  start_service
  write_version_metadata "$source_dir"

  log "done"
  log "server URL: http://$(hostname -I 2>/dev/null | awk '{print $1}'):$PORT_VALUE"
  log "config file: $ENV_FILE"
}

uninstall_service() {
  require_root
  load_existing_data_path
  load_existing_source_config
  validate_paths
  local program_exists="false"
  if [ -e "$APP_DIR" ] || [ -e "$VENV_DIR" ] || [ -e "$SERVICE_FILE" ]; then
    program_exists="true"
  fi

  if [ "$program_exists" = "false" ] && data_exists; then
    log "server program files are already absent, but database or configuration data remain"
  fi

  log "stopping $SERVICE_NAME"
  systemctl stop "$SERVICE_NAME.service" >/dev/null 2>&1 || true
  systemctl disable "$SERVICE_NAME.service" >/dev/null 2>&1 || true
  rm -f "$SERVICE_FILE"
  systemctl daemon-reload >/dev/null 2>&1 || true
  rm -rf "$APP_DIR" "$VENV_DIR" "$REPO_CACHE_DIR"

  case "$DATA_ACTION" in
    ask)
      if data_exists; then
        if [ -t 0 ] && [ -t 1 ]; then
          printf '[sena-repo] Delete database, generated data, and server configuration? [y/N] '
          local answer
          read -r answer
          case "$answer" in
            y|Y|yes|YES|Yes)
              DATA_ACTION="purge"
              ;;
            *)
              DATA_ACTION="keep"
              ;;
          esac
        else
          log "non-interactive uninstall: keeping database and configuration"
          log "run again with --purge-data to remove them"
          DATA_ACTION="keep"
        fi
      else
        DATA_ACTION="keep"
      fi
      ;;
  esac

  if [ "$DATA_ACTION" = "purge" ]; then
    case "$DATA_PATH" in
      ""|"/"|"/opt"|"/usr"|"/usr/local"|"/var"|"/srv"|"/etc")
        die "refusing to remove unsafe data path: $DATA_PATH"
        ;;
    esac
    log "removing database and generated data: $DATA_PATH"
    rm -rf -- "$DATA_PATH"
    log "removing server configuration: $ENV_DIR"
    rm -rf -- "$ENV_DIR"
    rm -f -- "$CONTROL_INSTALLER" "$CONTROL_UNINSTALLER"
    rmdir "$INSTALL_ROOT" >/dev/null 2>&1 || true
  else
    log "uninstalled server program files; data and config were kept"
    log "kept data: $DATA_PATH"
    log "kept config: $ENV_FILE"
    log "uninstaller kept at: $CONTROL_UNINSTALLER"
  fi
}

case "$ACTION" in
  install|update)
    if [ "$CHECK_ONLY" = "true" ]; then
      [ "$ACTION" = "install" ] || die "--check cannot be combined with --update"
      [ "$DATA_ACTION" = "ask" ] || die "--check cannot be combined with uninstall data options"
      check_installation
      exit $?
    fi
    if [ "$ACTION" = "install" ] && deployment_exists; then
      require_root
      load_existing_source_config
      validate_paths
      local_check_status=0
      check_remote_update || local_check_status=$?
      if [ "$local_check_status" -eq 0 ]; then
        exit 0
      elif [ "$local_check_status" -eq 2 ]; then
        die "version check failed; use --update to force an update"
      fi
      ACTION="update"
    fi
    if [ "$DATA_ACTION" != "ask" ]; then
      die "--keep-data and --purge-data can only be used with --uninstall"
    fi
    install_or_update
    ;;
  uninstall)
    [ "$CHECK_ONLY" = "false" ] || die "--check cannot be combined with --uninstall"
    uninstall_service
    ;;
esac
