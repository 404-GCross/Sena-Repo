#!/usr/bin/env bash
set -Eeuo pipefail

SERVICE_NAME="sena-repo"
DEFAULT_REPO_URL="https://github.com/404-GCross/Sena-Repo.git"
DEFAULT_REPO_REF="main"

ACTION="install"
DATA_ACTION="ask"
REQUESTED_DATA_PATH="${SENA_DATA_PATH:-}"
REQUESTED_REPO_URL="${SENA_REPO_URL:-}"
REQUESTED_REPO_REF="${SENA_REPO_REF:-}"
REQUESTED_CHANNEL="${SENA_CHANNEL:-}"
CHECK_ONLY="false"
while [ "$#" -gt 0 ]; do
  arg="$1"
  shift
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
    --channel)
      [ "$#" -gt 0 ] || {
        printf '[sena-repo] ERROR: --channel requires a value (dev|stable|beta)\n' >&2
        exit 2
      }
      REQUESTED_CHANNEL="$1"
      shift
      ;;
    --channel=*)
      REQUESTED_CHANNEL="${arg#--channel=}"
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
  sudo bash server/install.sh [--channel dev|stable|beta]
  sudo bash server/install.sh --update
  sudo bash server/install.sh --check
  sudo bash server/install.sh --uninstall [--keep-data|--purge-data]

Version channels:
  --channel dev      Latest main branch (default, rolling)
  --channel stable   Latest v* tag without a suffix
  --channel beta     Latest v* tag with a suffix (beta/rc)
  Every interactive run (install or update) asks which channel to use; pressing
  Enter keeps the current channel. The choice is stored in the install root.

Update behavior:
  --update      Fetch the latest source from SENA_REPO_URL/SENA_REPO_REF,
                keep existing data and configuration, then restart the service.
  --check       Check the remote source revision without installing or updating.

Supported Linux package managers:
  apt-get, dnf, yum, zypper, pacman. systemd is still required.

Environment overrides:
  SENA_INSTALL_ROOT=/opt/sena-repo
  SENA_DATA_PATH=/var/lib/sena-repo
  SENA_GAMES_PATH=/srv/sena-repo/games
  SENA_PATCH_DIR=/srv/sena-repo/steam_patch
  SENA_HOST=0.0.0.0
  SENA_PORT=11451
  SENA_PYTHON_BIN=/usr/bin/python3.11
  SENA_REPO_URL=https://github.com/404-GCross/Sena-Repo.git
                 (mirrors and self-hosted git URLs work too, for example
                  https://gh-proxy.com/https://github.com/404-GCross/Sena-Repo.git)
  SENA_REPO_REF=main
  SENA_CHANNEL=dev|stable|beta
  SENA_GH_MIRROR=https://gh-proxy.com/
                 (prefix used when the GitHub URL is unreachable; set it to an
                  empty value to disable the fallback)
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
CLI_BIN="/usr/local/bin/senacli"
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
GH_MIRROR="${SENA_GH_MIRROR-https://gh-proxy.com/}"
VERSION_VALUE=""
PYTHON_BIN="${SENA_PYTHON_BIN:-}"
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
  CLI_BIN="/usr/local/bin/senacli"
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

deployment_complete() {
  [ -x "$VENV_DIR/bin/python" ] || return 1
  [ -x "$APP_DIR/senacli.py" ] || return 1
  [ -x "$CLI_BIN" ] || return 1
  [ -f "$SERVICE_FILE" ] || return 1
  systemctl is-enabled "$SERVICE_NAME.service" >/dev/null 2>&1 || return 1
  return 0
}

installed_source_sha() {
  [ -f "$VERSION_FILE" ] || return 0
  sed -n 's/^SOURCE_SHA=//p' "$VERSION_FILE" | head -n 1
}

git_ls_remote() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 30 git ls-remote "$@"
  else
    git ls-remote "$@"
  fi
}

remote_source_sha() {
  command -v git >/dev/null 2>&1 || return 1
  git_ls_remote "$REPO_URL" "$REPO_REF" 2>/dev/null | awk 'NR == 1 { print $1; exit }'
}

repo_url_reachable() {
  command -v git >/dev/null 2>&1 || return 1
  git_ls_remote "$REPO_URL" main >/dev/null 2>&1
}

switch_to_gh_mirror() {
  [ -n "$GH_MIRROR" ] || return 1
  case "$REPO_URL" in
    "$GH_MIRROR"*) return 1 ;;
  esac
  REPO_URL="${GH_MIRROR%/}/$REPO_URL"
  return 0
}

ensure_repo_url() {
  if [ -n "$REQUESTED_REPO_URL" ]; then
    return 0
  fi
  if repo_url_reachable; then
    return 0
  fi
  if switch_to_gh_mirror; then
    log "unable to reach $DEFAULT_REPO_URL directly; using mirror $GH_MIRROR"
    if repo_url_reachable; then
      return 0
    fi
    log "warning: mirror $GH_MIRROR is not reachable either"
  else
    log "warning: unable to reach $REPO_URL (set SENA_REPO_URL or SENA_GH_MIRROR to change the source)"
  fi
  return 1
}

validate_channel() {
  case "$1" in
    dev|stable|beta) ;;
    *) die "unknown channel: $1 (expected dev, stable, or beta)" ;;
  esac
}

latest_tag_for_channel() {
  local channel="$1" line tag
  while IFS= read -r line; do
    tag="${line##*refs/tags/}"
    [ -n "$tag" ] || continue
    case "$channel" in
      stable)
        case "$tag" in *-*) continue ;; esac
        ;;
      beta)
        case "$tag" in *-*) ;; *) continue ;; esac
        ;;
    esac
    printf '%s\n' "$tag"
    return 0
  done < <(git_ls_remote --tags --refs --sort=-v:refname "$REPO_URL" 'v*' 2>/dev/null || true)
  return 1
}

latest_remote_tag() {
  local line
  line="$(git_ls_remote --tags --refs --sort=-v:refname "$REPO_URL" 'v*' 2>/dev/null | head -n 1 || true)"
  [ -n "$line" ] || return 1
  printf '%s\n' "${line##*refs/tags/}"
}

resolve_channel_ref() {
  local channel="$1" tag
  case "$channel" in
    dev)
      printf 'main\n'
      ;;
    stable)
      tag="$(latest_tag_for_channel stable || true)"
      [ -n "$tag" ] || die "no stable release yet (no v* tag without a suffix); use --channel dev or --ref <tag>"
      printf '%s\n' "$tag"
      ;;
    beta)
      tag="$(latest_remote_tag || true)"
      case "$tag" in
        "")
          die "no release tags on $REPO_URL yet; use --channel dev or --ref <tag>"
          ;;
        *-*)
          printf '%s\n' "$tag"
          ;;
        *)
          die "no test/pre-release available (the newest v* tag is stable: $tag); use --channel stable or --ref <tag>"
          ;;
      esac
      ;;
    *)
      die "unknown channel: $channel (expected dev, stable, or beta)"
      ;;
  esac
}

describe_ref_channel() {
  case "$REPO_REF" in
    main|master) printf '开发版（%s）' "$REPO_REF" ;;
    v*-*) printf '测试版（%s）' "$REPO_REF" ;;
    v*) printf '稳定版（%s）' "$REPO_REF" ;;
    *) printf '%s' "$REPO_REF" ;;
  esac
}

prompt_for_channel() {
  local answer current
  [ -r /dev/tty ] || return 1
  current="$(describe_ref_channel)"
  {
    printf '\n[sena-repo] 当前通道：%s\n' "$current"
    printf '请选择要使用的版本通道：\n'
    printf '  1) 稳定版（最新正式版 tag）\n'
    printf '  2) 测试版（最新预发布 beta/rc tag）\n'
    printf '  3) 开发版（main，滚动最新）\n'
    printf '直接回车保持当前通道，通道 [回车=%s]: ' "$current"
  } > /dev/tty
  if ! IFS= read -r answer < /dev/tty; then
    return 1
  fi
  case "$answer" in
    1|stable) printf 'stable\n' ;;
    2|beta) printf 'beta\n' ;;
    3|dev) printf 'dev\n' ;;
    *) printf '\n' ;;
  esac
}

installed_version_value() {
  local source_dir="$1" sha
  case "$REPO_REF" in
    v*) printf '%s\n' "$REPO_REF"; return 0 ;;
  esac
  sha="$(git -C "$source_dir" rev-parse --short=7 HEAD 2>/dev/null || true)"
  if [ -n "$sha" ]; then
    printf 'dev-%s\n' "$sha"
  else
    printf '%s\n' "$REPO_REF"
  fi
}

prompt_firewall_open() {
  local name="$1" command_text="$2" answer
  if [ -r /dev/tty ]; then
    printf '\n[sena-repo] %s 正在运行，但端口 %s/tcp 未放行。是否现在放行？[y/N] ' "$name" "$PORT_VALUE" > /dev/tty
    if IFS= read -r answer < /dev/tty; then
      case "$answer" in
        y|Y|yes|YES) return 0 ;;
      esac
    fi
    printf '[sena-repo] 已跳过；如需手动放行：%s\n' "$command_text" > /dev/tty
    return 1
  fi
  log "warning: $name is running but port $PORT_VALUE/tcp is not open; run: $command_text"
  return 1
}

ensure_firewall_port() {
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    if firewall-cmd --query-port="$PORT_VALUE/tcp" >/dev/null 2>&1; then
      log "firewall: port $PORT_VALUE/tcp is already open (firewalld)"
      return 0
    fi
    if prompt_firewall_open "firewalld" "firewall-cmd --permanent --add-port=$PORT_VALUE/tcp && firewall-cmd --reload"; then
      firewall-cmd --permanent --add-port="$PORT_VALUE/tcp" >/dev/null 2>&1 || true
      firewall-cmd --reload >/dev/null 2>&1 || true
      log "firewall: opened $PORT_VALUE/tcp (firewalld)"
    fi
    return 0
  fi
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    if ufw status 2>/dev/null | grep -q "^$PORT_VALUE/tcp"; then
      log "firewall: port $PORT_VALUE/tcp is already allowed (ufw)"
      return 0
    fi
    if prompt_firewall_open "ufw" "ufw allow $PORT_VALUE/tcp"; then
      ufw allow "$PORT_VALUE/tcp" >/dev/null 2>&1 || true
      log "firewall: allowed $PORT_VALUE/tcp (ufw)"
    fi
  fi
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
    log "Sena Repo server is already up to date ($current_sha) at $INSTALL_ROOT"
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
  if command -v apt-get >/dev/null 2>&1; then
    log "installing system dependencies with apt-get"
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
      zlib1g-dev
    apt-get install -y --no-install-recommends p7zip-full || true
  elif command -v dnf >/dev/null 2>&1; then
    log "installing system dependencies with dnf"
    dnf install -y \
      ca-certificates \
      curl \
      git \
      python3 \
      python3-pip \
      python3-devel \
      gcc \
      gcc-c++ \
      make \
      pkgconf-pkg-config \
      libffi-devel \
      openssl-devel \
      libxml2-devel \
      libxslt-devel \
      zlib-devel
    dnf install -y 7zip || dnf install -y p7zip p7zip-plugins || true
  elif command -v yum >/dev/null 2>&1; then
    log "installing system dependencies with yum"
    yum install -y \
      ca-certificates \
      curl \
      git \
      python3 \
      python3-pip \
      python3-devel \
      gcc \
      gcc-c++ \
      make \
      pkgconfig \
      libffi-devel \
      openssl-devel \
      libxml2-devel \
      libxslt-devel \
      zlib-devel
    yum install -y p7zip p7zip-plugins || true
  elif command -v zypper >/dev/null 2>&1; then
    log "installing system dependencies with zypper"
    zypper --non-interactive refresh || true
    zypper --non-interactive install --no-recommends \
      ca-certificates \
      curl \
      git \
      python3 \
      python3-pip \
      python3-devel \
      gcc \
      gcc-c++ \
      make \
      pkg-config \
      libffi-devel \
      libopenssl-devel \
      libxml2-devel \
      libxslt-devel \
      zlib-devel
    zypper --non-interactive install --no-recommends 7zip \
      || zypper --non-interactive install --no-recommends p7zip \
      || true
  elif command -v pacman >/dev/null 2>&1; then
    log "installing system dependencies with pacman"
    pacman -Sy --needed --noconfirm \
      ca-certificates \
      curl \
      git \
      python \
      python-pip \
      base-devel \
      pkgconf \
      libffi \
      openssl \
      libxml2 \
      libxslt \
      zlib \
      p7zip
  else
    log "no supported package manager found; continuing without automatic dependency installation"
    log "please ensure Python 3.10+, pip, venv, git, curl, build tools, OpenSSL/libffi/libxml2/libxslt/zlib headers, and 7z are installed"
  fi

  ensure_python_runtime
  warn_if_archive_tool_missing
}

python_version_ok() {
  "$1" - <<'PY' >/dev/null 2>&1
import sys
raise SystemExit(0 if sys.version_info >= (3, 10) else 1)
PY
}

ensure_python_runtime() {
  if [ -n "$PYTHON_BIN" ]; then
    command -v "$PYTHON_BIN" >/dev/null 2>&1 || die "SENA_PYTHON_BIN not found: $PYTHON_BIN"
    python_version_ok "$PYTHON_BIN" || die "SENA_PYTHON_BIN must point to Python 3.10 or newer: $PYTHON_BIN"
    return
  fi

  local candidate
  for candidate in python3.12 python3.11 python3.10 python3; do
    if command -v "$candidate" >/dev/null 2>&1 && python_version_ok "$candidate"; then
      PYTHON_BIN="$(command -v "$candidate")"
      log "using Python runtime: $PYTHON_BIN"
      return
    fi
  done

  die "Python 3.10 or newer is required; install it or set SENA_PYTHON_BIN=/path/to/python3"
}

archive_tool_available() {
  command -v 7zz >/dev/null 2>&1 \
    || command -v 7z >/dev/null 2>&1 \
    || command -v 7za >/dev/null 2>&1
}

warn_if_archive_tool_missing() {
  if archive_tool_available; then
    return
  fi
  log "warning: 7z was not found; .rar/.7z Steam patch archive inspection will be unavailable until 7z/p7zip is installed"
  log "warning: on RHEL/Rocky/Alma/openEuler, you may need to enable EPEL or install the 7zip/p7zip package manually"
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

run_git_source_fetch() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 300 git -C "$REPO_CACHE_DIR" fetch --depth 1 origin "$REPO_REF"
  else
    git -C "$REPO_CACHE_DIR" fetch --depth 1 origin "$REPO_REF"
  fi
}

run_git_source_clone() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 300 git clone --depth 1 --branch "$REPO_REF" "$REPO_URL" "$REPO_CACHE_DIR"
  else
    git clone --depth 1 --branch "$REPO_REF" "$REPO_URL" "$REPO_CACHE_DIR"
  fi
}

remote_server_dir() {
  mkdir -p "$INSTALL_ROOT"
  local attempt
  if [ -d "$REPO_CACHE_DIR/.git" ]; then
    log "updating cached source from $REPO_URL ($REPO_REF)"
    for attempt in 1 2 3; do
      git -C "$REPO_CACHE_DIR" remote set-url origin "$REPO_URL"
      if run_git_source_fetch; then
        git -C "$REPO_CACHE_DIR" checkout --force FETCH_HEAD
        break
      fi
      log "source fetch failed (attempt $attempt/3)"
      if [ "$attempt" -ge 3 ]; then
        die "failed to fetch $REPO_REF from $REPO_URL; set SENA_REPO_URL to another mirror or check the network"
      fi
      switch_to_gh_mirror && log "switched source to mirror $GH_MIRROR" || true
      sleep 3
    done
  else
    rm -rf "$REPO_CACHE_DIR"
    log "cloning source from $REPO_URL ($REPO_REF)"
    for attempt in 1 2 3; do
      if run_git_source_clone; then
        break
      fi
      log "source clone failed (attempt $attempt/3)"
      if [ "$attempt" -ge 3 ]; then
        die "failed to clone $REPO_REF from $REPO_URL; set SENA_REPO_URL to another mirror or check the network"
      fi
      switch_to_gh_mirror && log "switched source to mirror $GH_MIRROR" || true
      sleep 3
    done
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

install_cli_command() {
  log "installing senacli to $CLI_BIN"
  chmod 0755 "$APP_DIR/senacli.py"
  cat > "$CLI_BIN" <<EOF
#!/usr/bin/env bash
exec "$VENV_DIR/bin/python" "$APP_DIR/senacli.py" "\$@"
EOF
  chmod 0755 "$CLI_BIN"
}

remove_cli_command() {
  if [ -L "$CLI_BIN" ]; then
    local target
    target="$(readlink "$CLI_BIN" 2>/dev/null || true)"
    if [ "$target" = "$APP_DIR/senacli.py" ]; then
      rm -f -- "$CLI_BIN"
    fi
    return
  fi
  if [ -f "$CLI_BIN" ] && grep -Fq "$APP_DIR/senacli.py" "$CLI_BIN" 2>/dev/null; then
    rm -f -- "$CLI_BIN"
  fi
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

update_env_version() {
  [ -n "$VERSION_VALUE" ] || return 0
  [ -f "$ENV_FILE" ] || return 0
  local current tmp
  current="$(sed -n 's/^SENA_VERSION=//p' "$ENV_FILE" | head -n 1)"
  [ "$current" = "$VERSION_VALUE" ] && return 0
  tmp="$ENV_FILE.tmp"
  umask 077
  { grep -v '^SENA_VERSION=' "$ENV_FILE" || true; } > "$tmp"
  printf 'SENA_VERSION=%s\n' "$VERSION_VALUE" >> "$tmp"
  mv -f -- "$tmp" "$ENV_FILE"
  log "updated SENA_VERSION=$VERSION_VALUE in $ENV_FILE"
}

write_environment_file() {
  mkdir -p "$ENV_DIR" "$DATA_PATH" "$GAMES_PATH" "$PATCH_DIR"

  if [ -f "$ENV_FILE" ]; then
    log "keeping existing environment file: $ENV_FILE"
    update_env_version
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
    printf 'SENA_VERSION=%s\n' "$VERSION_VALUE"
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
  "$PYTHON_BIN" -m venv "$VENV_DIR"
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
  VERSION_VALUE="$(installed_version_value "$source_dir")"
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
  install_cli_command
  write_systemd_service
  start_service
  ensure_firewall_port
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
  remove_cli_command
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
    if [ "$DATA_ACTION" != "ask" ]; then
      die "--keep-data and --purge-data can only be used with --uninstall"
    fi
    require_root
    load_existing_source_config
    validate_paths
    if [ -n "$REQUESTED_CHANNEL" ]; then
      validate_channel "$REQUESTED_CHANNEL"
    fi
    ensure_repo_url || true
    selected_channel=""
    if [ -n "$REQUESTED_CHANNEL" ]; then
      selected_channel="$REQUESTED_CHANNEL"
    elif [ -z "$REQUESTED_REPO_REF" ]; then
      selected_channel="$(prompt_for_channel || true)"
    fi
    if [ -n "$selected_channel" ] && [ -z "$REQUESTED_REPO_REF" ]; then
      REPO_REF="$(resolve_channel_ref "$selected_channel")"
      log "selected channel: $selected_channel ($REPO_REF)"
    fi
    if [ "$ACTION" = "install" ] && deployment_exists; then
      local_check_status=0
      check_remote_update || local_check_status=$?
      if [ "$local_check_status" -eq 0 ]; then
        if deployment_complete; then
          exit 0
        fi
        log "installation at $INSTALL_ROOT is incomplete; repairing it"
      elif [ "$local_check_status" -eq 2 ]; then
        die "version check failed; use --update to force an update"
      fi
      ACTION="update"
    fi
    install_or_update
    ;;
  uninstall)
    [ "$CHECK_ONLY" = "false" ] || die "--check cannot be combined with --uninstall"
    uninstall_service
    ;;
esac
