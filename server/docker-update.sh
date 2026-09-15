#!/usr/bin/env bash
# Quick update helper for Docker deployments of Sena Repo.
#
# The script reads the running container's configuration back out of Docker,
# pulls the image the container was created from (or the one you ask for), and
# recreates the container with the same mounts, ports, environment variables and
# restart policy. Data volumes are untouched; a failed health check rolls the
# container back to the previous image.

set -Eeuo pipefail

CONTAINER="${SENA_CONTAINER:-sena-repo}"
DEFAULT_REPO="${SENA_DOCKER_REPO:-404gcross/sena-repo}"
HEALTH_TIMEOUT="${SENA_HEALTH_TIMEOUT:-90}"

REQUESTED_CHANNEL=""
REQUESTED_IMAGE=""
FORCE="false"
DRY_RUN="false"
PRUNE="true"
ASSUME_YES="false"

ENV_FILE=""
declare -a RUN_ARGS=()
declare -a ENV_NAMES=()
declare -a PORT_BINDINGS=()

log() {
  printf '[sena-repo] %s\n' "$*" >&2
}

die() {
  printf '[sena-repo] ERROR: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [ -n "$ENV_FILE" ] && [ -f "$ENV_FILE" ]; then
    rm -f "$ENV_FILE"
  fi
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
Sena Repo Docker update helper.

Usage:
  sudo bash server/docker-update.sh [options]

Defaults:
  Container        sena-repo            (-c/--container to change)
  Image            same reference the container was created from
  Health timeout   90s                  (SENA_HEALTH_TIMEOUT to change)

Options:
  -c, --container NAME   Container to update
      --channel NAME     Update to a channel tag: release|pre-release|dev
      --image REF        Update to an explicit image reference
      --force            Recreate even when the image is already up to date
      --dry-run          Print what would run without touching Docker
      --no-prune         Keep dangling images after a successful update
  -y, --yes              Do not ask for confirmation
  -h, --help             Show this help

What it preserves:
  bind mounts and named volumes, published ports, environment variables,
  restart policy, network mode, labels and resource limits.

Safety:
  Recreating a container that Compose or the NAS UI manages by itself is not
  supported: the script detects a Compose label and switches to
  "docker compose pull && docker compose up -d" instead of docker run.
  Settings the script cannot reproduce (privileged, extra capabilities,
  devices, extra hosts, custom DNS/sysctls, overridden entrypoint/command,
  container-level healthcheck) abort the update unless --force is given.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -c|--container)
      [ $# -ge 2 ] || die "$1 requires a value"
      CONTAINER="$2"
      shift 2
      ;;
    --channel)
      [ $# -ge 2 ] || die "$1 requires a value"
      REQUESTED_CHANNEL="$2"
      shift 2
      ;;
    --image)
      [ $# -ge 2 ] || die "$1 requires a value"
      REQUESTED_IMAGE="$2"
      shift 2
      ;;
    --force)
      FORCE="true"
      shift
      ;;
    --dry-run)
      DRY_RUN="true"
      shift
      ;;
    --no-prune)
      PRUNE="false"
      shift
      ;;
    -y|--yes)
      ASSUME_YES="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1 (try --help)"
      ;;
  esac
done

case "$REQUESTED_CHANNEL" in
  "")
    ;;
  release)
    REQUESTED_IMAGE="${DEFAULT_REPO}:latest"
    ;;
  pre-release)
    REQUESTED_IMAGE="${DEFAULT_REPO}:pre-release"
    ;;
  dev)
    REQUESTED_IMAGE="${DEFAULT_REPO}:dev"
    ;;
  *)
    die "--channel must be release, pre-release or dev"
    ;;
esac

command -v docker >/dev/null 2>&1 || die "docker command not found"

if ! docker info >/dev/null 2>&1; then
  if [ "$(id -u)" -ne 0 ]; then
    die "cannot talk to the Docker daemon; run this script as root (for example: sudo bash $0)"
  fi
  die "cannot talk to the Docker daemon"
fi

inspect() {
  docker inspect -f "$1" "$CONTAINER" 2>/dev/null || true
}

docker container inspect "$CONTAINER" >/dev/null 2>&1 || die "container not found: $CONTAINER"

COMPOSE_FILE="$(inspect '{{index .Config.Labels "com.docker.compose.project.config_files"}}')"
CURRENT_IMAGE_REF="$(inspect '{{.Config.Image}}')"
OLD_IMAGE_ID="$(inspect '{{.Image}}')"

if [ -z "$REQUESTED_IMAGE" ]; then
  case "$CURRENT_IMAGE_REF" in
    ""|sha256:*|*@sha256:*)
      die "container has no usable image reference ($CURRENT_IMAGE_REF); pass --image or --channel"
      ;;
  esac
  TARGET_REF="$CURRENT_IMAGE_REF"
else
  TARGET_REF="$REQUESTED_IMAGE"
fi

data_dir_of_container() {
  inspect '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}'
}

if [ -n "$COMPOSE_FILE" ]; then
  update_via_compose() {
    local compose_args=(-f "$COMPOSE_FILE")
    log "container is managed by Compose ($COMPOSE_FILE)"
    if [ "$DRY_RUN" = "true" ]; then
      log "dry-run: docker compose ${compose_args[*]} pull"
      log "dry-run: docker compose ${compose_args[*]} up -d"
      return 0
    fi
    docker compose "${compose_args[@]}" pull || die "docker compose pull failed"
    docker compose "${compose_args[@]}" up -d || die "docker compose up failed"
    log "Compose update finished; the container is not recreated by docker run here,"
    log "so no automatic rollback is available. Previous image: ${OLD_IMAGE_ID:0:12}"
    log "Roll back with: docker compose ${compose_args[*]} up -d --force-recreate"
    return 0
  }
  update_via_compose
  exit 0
fi

collect_unsupported() {
  inspect '{{if .HostConfig.Privileged}}privileged{{println}}{{end}}{{if .HostConfig.CapAdd}}cap_add{{println}}{{end}}{{if .HostConfig.CapDrop}}cap_drop{{println}}{{end}}{{if .HostConfig.Devices}}devices{{println}}{{end}}{{if .HostConfig.DeviceRequests}}device_requests{{println}}{{end}}{{if .HostConfig.ExtraHosts}}extra_hosts{{println}}{{end}}{{if .HostConfig.Dns}}dns{{println}}{{end}}{{if .HostConfig.DnsOptions}}dns_options{{println}}{{end}}{{if .HostConfig.DnsSearch}}dns_search{{println}}{{end}}{{if .HostConfig.Sysctls}}sysctls{{println}}{{end}}{{if .HostConfig.Ulimits}}ulimits{{println}}{{end}}{{if .HostConfig.Tmpfs}}tmpfs{{println}}{{end}}{{if .HostConfig.SecurityOpt}}security_opt{{println}}{{end}}{{if .HostConfig.PidMode}}pid_mode={{.HostConfig.PidMode}}{{println}}{{end}}{{if .HostConfig.IpcMode}}ipc_mode={{.HostConfig.IpcMode}}{{println}}{{end}}{{if .HostConfig.UtsMode}}uts_mode{{println}}{{end}}{{if .HostConfig.UsernsMode}}userns_mode{{println}}{{end}}{{if .HostConfig.CgroupParent}}cgroup_parent{{println}}{{end}}{{if .HostConfig.Runtime}}runtime{{println}}{{end}}{{if .HostConfig.GroupAdd}}group_add{{println}}{{end}}{{if .HostConfig.AutoRemove}}auto_remove{{println}}{{end}}{{if .HostConfig.PublishAllPorts}}publish_all_ports{{println}}{{end}}{{if .Config.Healthcheck}}custom_healthcheck{{println}}{{end}}'
}

UNSUPPORTED="$(collect_unsupported | tr '\n' ' ' | sed 's/ *$//')"

IMAGE_CMD="$(docker image inspect -f '{{json .Config.Cmd}}' "$OLD_IMAGE_ID" 2>/dev/null || true)"
IMAGE_ENTRYPOINT="$(docker image inspect -f '{{json .Config.Entrypoint}}' "$OLD_IMAGE_ID" 2>/dev/null || true)"
CONTAINER_CMD="$(inspect '{{json .Config.Cmd}}')"
CONTAINER_ENTRYPOINT="$(inspect '{{json .Config.Entrypoint}}')"
if [ "$CONTAINER_CMD" != "$IMAGE_CMD" ] || [ "$CONTAINER_ENTRYPOINT" != "$IMAGE_ENTRYPOINT" ]; then
  UNSUPPORTED="$(printf '%s custom_command' "$UNSUPPORTED" | sed 's/^ *//')"
fi

LOG_TYPE="$(inspect '{{.HostConfig.LogConfig.Type}}')"
case "$LOG_TYPE" in
  ""|json-file)
    ;;
  *)
    UNSUPPORTED="$(printf '%s log_driver=%s' "$UNSUPPORTED" "$LOG_TYPE" | sed 's/^ *//')"
    ;;
esac

if [ -n "$UNSUPPORTED" ] && [ "$FORCE" != "true" ]; then
  die "container uses settings this script cannot reproduce: $UNSUPPORTED
Recreate it manually, or re-run with --force to ignore them."
fi

if [ -n "$UNSUPPORTED" ]; then
  log "WARNING: ignoring settings that will not be reproduced: $UNSUPPORTED"
fi

ENV_TMP="$(mktemp)"
chmod 600 "$ENV_TMP"
ENV_FILE="$ENV_TMP"
SKIP_ENV=" PATH LANG LC_ALL LANGUAGE GPG_KEY PYTHON_VERSION PYTHON_SHA256 PYTHONUNBUFFERED PYTHONDONTWRITEBYTECODE HOME HOSTNAME TERM "
while IFS= read -r line; do
  [ -n "$line" ] || continue
  key="${line%%=*}"
  case "$SKIP_ENV" in
    *" $key "*) continue ;;
  esac
  case "$key" in
    *[!A-Za-z0-9_]*) continue ;;
  esac
  printf '%s\n' "$line" >>"$ENV_TMP"
  ENV_NAMES+=("$key")
done < <(inspect '{{range .Config.Env}}{{println .}}{{end}}')

RUN_ARGS+=(--name "$CONTAINER")

while IFS='|' read -r mtype msource mdest mrw; do
  [ -n "$mtype" ] || continue
  case "$mtype" in
    bind)
      [ -n "$msource" ] || continue
      if [ "$mrw" = "true" ]; then
        RUN_ARGS+=(-v "${msource}:${mdest}")
      else
        RUN_ARGS+=(-v "${msource}:${mdest}:ro")
      fi
      ;;
    volume)
      [ -n "$msource" ] || continue
      if [ "$mrw" = "true" ]; then
        RUN_ARGS+=(-v "${msource}:${mdest}")
      else
        RUN_ARGS+=(-v "${msource}:${mdest}:ro")
      fi
      ;;
    *)
      die "unsupported mount type: $mtype ($mdest)"
      ;;
  esac
done < <(inspect '{{range .Mounts}}{{.Type}}|{{if eq .Type "bind"}}{{.Source}}{{else}}{{.Name}}{{end}}|{{.Destination}}|{{.RW}}{{println}}{{end}}')

while IFS='|' read -r port_proto hostip hostport; do
  [ -n "$port_proto" ] || continue
  [ -n "$hostport" ] || continue
  PORT_BINDINGS+=("${port_proto}|${hostip}|${hostport}")
done < <(inspect '{{range $p, $conf := .HostConfig.PortBindings}}{{range $conf}}{{$p}}|{{.HostIp}}|{{.HostPort}}{{println}}{{end}}{{end}}')

declare -A PORT_DONE=()
for binding in "${PORT_BINDINGS[@]}"; do
  IFS='|' read -r port_proto ipv4_hostip ipv4_hostport <<<"$binding"
  [ -n "${PORT_DONE[$port_proto]:-}" ] && continue
  if [ "$ipv4_hostip" = "::" ]; then
    for other in "${PORT_BINDINGS[@]}"; do
      IFS='|' read -r other_proto other_ip other_port <<<"$other"
      if [ "$other_proto" = "$port_proto" ] && [ "$other_ip" != "::" ] && [ -n "$other_port" ]; then
        IFS='|' read -r port_proto ipv4_hostip ipv4_hostport <<<"$other"
        break
      fi
    done
    [ "$ipv4_hostip" = "::" ] || continue
    RUN_ARGS+=(-p "[::]:${ipv4_hostport}:${port_proto}")
    PORT_DONE[$port_proto]="1"
    continue
  fi
  case "$ipv4_hostip" in
    ""|"0.0.0.0")
      RUN_ARGS+=(-p "${ipv4_hostport}:${port_proto}")
      ;;
    *)
      RUN_ARGS+=(-p "${ipv4_hostip}:${ipv4_hostport}:${port_proto}")
      ;;
  esac
  PORT_DONE[$port_proto]="1"
done

RESTART_NAME="$(inspect '{{.HostConfig.RestartPolicy.Name}}')"
RESTART_RETRIES="$(inspect '{{.HostConfig.RestartPolicy.MaximumRetryCount}}')"
case "$RESTART_NAME" in
  ""|no)
    ;;
  on-failure)
    if [ -n "$RESTART_RETRIES" ] && [ "$RESTART_RETRIES" != "0" ]; then
      RUN_ARGS+=(--restart "on-failure:${RESTART_RETRIES}")
    else
      RUN_ARGS+=(--restart on-failure)
    fi
    ;;
  *)
    RUN_ARGS+=(--restart "$RESTART_NAME")
    ;;
esac

NETWORK_MODE="$(inspect '{{.HostConfig.NetworkMode}}')"
case "$NETWORK_MODE" in
  ""|default|bridge)
    ;;
  *)
    RUN_ARGS+=(--network "$NETWORK_MODE")
    ;;
esac

USER_VALUE="$(inspect '{{.Config.User}}')"
[ -n "$USER_VALUE" ] && RUN_ARGS+=(--user "$USER_VALUE")

MEMORY_LIMIT="$(inspect '{{.HostConfig.Memory}}')"
if [ -n "$MEMORY_LIMIT" ] && [ "$MEMORY_LIMIT" != "0" ]; then
  RUN_ARGS+=(--memory "$MEMORY_LIMIT")
fi

NANO_CPUS="$(inspect '{{.HostConfig.NanoCpus}}')"
if [ -n "$NANO_CPUS" ] && [ "$NANO_CPUS" != "0" ]; then
  CPUS="$(awk -v nano="$NANO_CPUS" 'BEGIN { printf "%.2f", nano / 1000000000 }')"
  RUN_ARGS+=(--cpus "$CPUS")
fi

if [ "$(inspect '{{.HostConfig.Init}}')" = "true" ]; then
  RUN_ARGS+=(--init)
fi
if [ "$(inspect '{{.HostConfig.ReadonlyRootfs}}')" = "true" ]; then
  RUN_ARGS+=(--read-only)
fi

if [ "${#ENV_NAMES[@]}" -gt 0 ]; then
  RUN_ARGS+=(--env-file "$ENV_FILE")
fi

EXPECTED_MOUNTS="$(inspect '{{len .Mounts}}')"
RECONSTRUCTED_MOUNTS="$(printf '%s\n' "${RUN_ARGS[@]}" | grep -c '^-v$' || true)"
if [ -n "$EXPECTED_MOUNTS" ] && [ "$RECONSTRUCTED_MOUNTS" -lt "$EXPECTED_MOUNTS" ] && [ "$FORCE" != "true" ]; then
  die "could not read every mount back from the container ($RECONSTRUCTED_MOUNTS/$EXPECTED_MOUNTS); refusing to recreate it"
fi

EXPECTED_PORTS="$(inspect '{{len .HostConfig.PortBindings}}')"
if [ -n "$EXPECTED_PORTS" ] && [ "${#PORT_DONE[@]}" -lt "$EXPECTED_PORTS" ]; then
  log "WARNING: rebuilt ${#PORT_DONE[@]} of $EXPECTED_PORTS published port(s)"
fi

while IFS= read -r label; do
  [ -n "$label" ] || continue
  case "$label" in
    com.docker.compose.*) continue ;;
  esac
  RUN_ARGS+=(--label "$label")
done < <(inspect '{{range $k, $v := .Config.Labels}}{{$k}}={{$v}}{{println}}{{end}}')

run_container() {
  local image_id="$1"
  docker run -d "${RUN_ARGS[@]}" "$image_id"
}

wait_healthy() {
  local deadline=$((SECONDS + HEALTH_TIMEOUT))
  local has_health status running
  has_health="$(inspect '{{if .State.Health}}1{{end}}')"
  while [ "$SECONDS" -lt "$deadline" ]; do
    if [ -n "$has_health" ]; then
      status="$(inspect '{{.State.Health.Status}}')"
      case "$status" in
        healthy)
          return 0
          ;;
        unhealthy)
          return 1
          ;;
      esac
    else
      running="$(inspect '{{.State.Running}}')"
      if [ "$running" = "true" ]; then
        sleep 3
        return 0
      fi
    fi
    sleep 3
  done
  return 1
}

if [ "$DRY_RUN" = "true" ]; then
  log "dry-run: docker pull $TARGET_REF"
  log "dry-run: current image id ${OLD_IMAGE_ID:0:12}"
  printf '[sena-repo] dry-run: docker rm -f %s && docker run -d' "$CONTAINER" >&2
  printf ' %q' "${RUN_ARGS[@]}" >&2
  printf ' <new image id>\n' >&2
  if [ "${#ENV_NAMES[@]}" -gt 0 ]; then
    log "dry-run: env-file would carry: ${ENV_NAMES[*]} (values are not printed)"
  fi
  exit 0
fi

log "pulling $TARGET_REF"
docker pull "$TARGET_REF" >/dev/null || die "docker pull failed: $TARGET_REF"
NEW_IMAGE_ID="$(docker image inspect -f '{{.Id}}' "$TARGET_REF")"
NEW_IMAGE_CREATED="$(docker image inspect -f '{{.Created}}' "$TARGET_REF" 2>/dev/null || true)"

if [ "$NEW_IMAGE_ID" = "$OLD_IMAGE_ID" ] && [ "$FORCE" != "true" ]; then
  log "already up to date (${NEW_IMAGE_ID:0:12})"
  exit 0
fi

DATA_HOST_DIR="$(data_dir_of_container)"
INSPECT_DIR="${DATA_HOST_DIR:-$PWD}/backups/docker"
mkdir -p "$INSPECT_DIR" 2>/dev/null || INSPECT_DIR="$PWD"
INSPECT_BACKUP="${INSPECT_DIR}/inspect-$(date +%Y%m%d-%H%M%S).json"
docker inspect "$CONTAINER" >"$INSPECT_BACKUP" || log "WARNING: could not save $INSPECT_BACKUP"
chmod 600 "$INSPECT_BACKUP" 2>/dev/null || true

RUNNING_BEFORE="$(inspect '{{.State.Running}}')"
log "recreating $CONTAINER: ${OLD_IMAGE_ID:0:12} -> ${NEW_IMAGE_ID:0:12}"
docker rm -f "$CONTAINER" >/dev/null || die "failed to remove the old container"

if ! run_container "$NEW_IMAGE_ID" >/dev/null; then
  log "failed to start the new container; rolling back"
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  run_container "$OLD_IMAGE_ID" >/dev/null || die "rollback failed; check $INSPECT_BACKUP"
  die "update failed, container rolled back to ${OLD_IMAGE_ID:0:12}"
fi

if wait_healthy; then
  log "container is healthy on ${NEW_IMAGE_ID:0:12}"
else
  log "health check did not pass; rolling back to ${OLD_IMAGE_ID:0:12}"
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  run_container "$OLD_IMAGE_ID" >/dev/null || die "rollback failed; check $INSPECT_BACKUP"
  if wait_healthy; then
    log "rolled back and healthy again"
  else
    log "WARNING: rolled back container is not healthy either; check docker logs $CONTAINER"
  fi
  die "update failed; previous image restored (inspect backup: $INSPECT_BACKUP)"
fi

if [ "$RUNNING_BEFORE" != "true" ]; then
  log "container was stopped before the update; leaving it stopped"
  docker stop "$CONTAINER" >/dev/null || true
fi

if [ "$PRUNE" = "true" ]; then
  docker image prune -f >/dev/null 2>&1 || true
fi

log "done"
log "image: $TARGET_REF (${NEW_IMAGE_ID:0:12}, built ${NEW_IMAGE_CREATED:-unknown})"
log "previous image id: ${OLD_IMAGE_ID:0:12} (remove it later with: docker image rm ${OLD_IMAGE_ID:0:12})"
log "inspect backup: $INSPECT_BACKUP"
