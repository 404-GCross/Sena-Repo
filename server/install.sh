#!/usr/bin/env bash
set -Eeuo pipefail

SERVICE_NAME="sena-repo"
DEFAULT_REPO_URL="https://github.com/404-GCross/Sena-Repo.git"
DEFAULT_REPO_REF="dev"

ACTION="install"
for arg in "$@"; do
  case "$arg" in
    --install)
      ACTION="install"
      ;;
    --update)
      ACTION="update"
      ;;
    --uninstall)
      ACTION="uninstall"
      ;;
    -h|--help)
      cat <<'EOF'
Sena Repo server bare-metal installer.

Usage:
  sudo bash server/install.sh
  sudo bash server/install.sh --update
  sudo bash server/install.sh --uninstall

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
  case "$INSTALL_ROOT" in
    ""|"/"|"/opt"|"/usr"|"/usr/local"|"/var"|"/srv"|"/etc")
      die "unsafe SENA_INSTALL_ROOT: $INSTALL_ROOT"
      ;;
  esac
  case "$DATA_PATH" in
    ""|"/"|"/opt"|"/usr"|"/usr/local"|"/var"|"/srv"|"/etc")
      die "unsafe SENA_DATA_PATH: $DATA_PATH"
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
  if local_server_dir >/dev/null 2>&1; then
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
  validate_paths
  detect_arch
  install_system_dependencies
  source_dir="$(resolve_source_server_dir)"
  stop_service_if_exists
  copy_server_files "$source_dir"
  write_environment_file
  install_python_dependencies
  write_systemd_service
  start_service

  log "done"
  log "server URL: http://$(hostname -I 2>/dev/null | awk '{print $1}'):$PORT_VALUE"
  log "config file: $ENV_FILE"
}

uninstall_service() {
  require_root
  log "stopping $SERVICE_NAME"
  systemctl stop "$SERVICE_NAME.service" >/dev/null 2>&1 || true
  systemctl disable "$SERVICE_NAME.service" >/dev/null 2>&1 || true
  rm -f "$SERVICE_FILE"
  systemctl daemon-reload >/dev/null 2>&1 || true
  rm -rf "$APP_DIR" "$VENV_DIR" "$REPO_CACHE_DIR"
  rmdir "$INSTALL_ROOT" >/dev/null 2>&1 || true
  log "uninstalled server program files; data and config were kept"
  log "kept data: $DATA_PATH"
  log "kept config: $ENV_FILE"
}

case "$ACTION" in
  install|update)
    install_or_update
    ;;
  uninstall)
    uninstall_service
    ;;
esac
