#!/usr/bin/env bash
set -euo pipefail

# Keeps the containerd image store and the BuildKit state of a self-hosted
# runner host in RAM, so builds unpack and write layers to memory instead of
# the SSDs. Volumes, including buildcache-registry-data, stay on disk: after a
# reboot the store is empty and the first builds pull from the registry cache.
#
#   containerd-on-tmpfs.sh install    mount the tmpfs, limit the build cache, restart docker
#   containerd-on-tmpfs.sh rollback   back to the on-disk store, which the tmpfs only hid
#   containerd-on-tmpfs.sh status
#
# Requires the containerd image store (migrate-to-containerd-store.sh). Run as
# root while no job is active; runner services are stopped meanwhile.

SIZE="${SIZE:-80G}"
BUILDKIT_SIZE="${BUILDKIT_SIZE:-2G}"
GC_MAX_USED="${GC_MAX_USED:-35GB}"
GC_MIN_FREE="${GC_MIN_FREE:-15GB}"
IMAGE_MAX_AGE="${IMAGE_MAX_AGE:-48h}"
JOB_RESERVE="${JOB_RESERVE:-16G}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DAEMON_JSON="/etc/docker/daemon.json"
DAEMON_BACKUP="/etc/docker/daemon.json.before-tmpfs"
UNIT_DIR="/etc/systemd/system"
MOUNT_PATHS="/var/lib/containerd /var/lib/docker/buildkit"
ENSURE_SCRIPT="/usr/local/sbin/ensure-buildcache-registry.sh"
ENSURE_UNIT="buildcache-registry-ensure.service"
REGISTRY_SCRIPT="/usr/local/sbin/setup-local-registry.sh"
CRON_FILE="/etc/cron.d/buildcache-tmpfs"

mount_unit() { systemd-escape -p --suffix=mount "$1"; }

require_idle_root() {
  [ "$(id -u)" = "0" ] || { echo "run as root"; exit 1; }
  if pgrep -f 'Runner.Worker' >/dev/null; then
    echo "a runner job is active, try again when the runners are idle"
    exit 1
  fi
}

stop_runners() {
  [ -z "${RUNNERS_STOPPED:-}" ] || return 0
  RUNNERS_STOPPED=1
  RUNNERS="$(systemctl list-units --type=service --state=running --no-legend --plain 'actions.runner.*' | awk '{print $1}')"
  echo "== stopping runners: ${RUNNERS:-none}"
  for unit in $RUNNERS; do systemctl stop "$unit"; done
  trap 'echo "== starting runners"; for unit in $RUNNERS; do systemctl start "$unit"; done' EXIT
}

stop_docker() {
  echo "== stopping docker and containerd"
  systemctl stop docker.socket docker.service containerd.service
}

start_docker() {
  echo "== starting containerd and docker"
  systemctl start containerd.service docker.socket docker.service
  for _ in $(seq 1 60); do docker info >/dev/null 2>&1 && return 0; sleep 1; done
  echo "docker did not come up"
  return 1
}

do_status() {
  for p in $MOUNT_PATHS; do
    if mountpoint -q "$p"; then
      df -h --output=target,size,used,avail "$p" | tail -1
    else
      echo "$p: on disk"
    fi
  done
  docker info --format 'store: {{.Driver}} {{json .DriverStatus}}'
  docker buildx inspect default 2>/dev/null | grep -iE 'gc policy|max used|min free|reserved' || true
  docker ps --filter name=buildcache-registry --format 'registry: {{.Status}}'
}

do_install() {
  require_idle_root
  command -v jq >/dev/null || { echo "jq is required"; exit 1; }
  docker info --format '{{json .DriverStatus}}' | grep -q 'io.containerd.snapshotter' \
    || { echo "the containerd image store is not active, run migrate-to-containerd-store.sh first"; exit 1; }
  if mountpoint -q /var/lib/containerd; then
    echo "already on tmpfs"; do_status; exit 0
  fi
  avail_kb=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
  need_kb=$(( ($(numfmt --from=iec "$SIZE") + $(numfmt --from=iec "$JOB_RESERVE")) / 1024 ))
  [ "$avail_kb" -gt "$need_kb" ] || { echo "not enough free memory for a ${SIZE} tmpfs plus ${JOB_RESERVE} for jobs"; exit 1; }

  stop_runners

  echo "== writing mount units"
  for p in $MOUNT_PATHS; do
    size="$SIZE"; [ "$p" = /var/lib/docker/buildkit ] && size="$BUILDKIT_SIZE"
    cat > "$UNIT_DIR/$(mount_unit "$p")" <<EOF
[Unit]
Description=tmpfs for $p (action.build)
Before=containerd.service docker.service

[Mount]
What=tmpfs
Where=$p
Type=tmpfs
Options=size=$size,mode=0711

[Install]
WantedBy=local-fs.target
EOF
  done
  for svc in containerd docker; do
    mkdir -p "$UNIT_DIR/$svc.service.d"
    printf '[Unit]\nRequiresMountsFor=%s\n' "$MOUNT_PATHS" > "$UNIT_DIR/$svc.service.d/tmpfs.conf"
  done

  echo "== limiting the build cache to ${GC_MAX_USED}, keeping ${GC_MIN_FREE} free"
  [ -f "$DAEMON_JSON" ] || echo '{}' > "$DAEMON_JSON"
  [ -f "$DAEMON_BACKUP" ] || cp "$DAEMON_JSON" "$DAEMON_BACKUP"
  jq --arg max "$GC_MAX_USED" --arg free "$GC_MIN_FREE" \
    '.builder.gc = {"enabled": true, "defaultMaxUsedSpace": $max, "defaultMinFreeSpace": $free}' \
    "$DAEMON_BACKUP" > "$DAEMON_JSON"

  echo "== installing the registry recreation after boot"
  install -m 0755 "$SCRIPT_DIR/setup-local-registry.sh" "$REGISTRY_SCRIPT"
  cat > "$ENSURE_SCRIPT" <<EOF
#!/usr/bin/env bash
set -euo pipefail
# The registry container survives in /var/lib/docker, its image did not.
if [ "\$(docker inspect -f '{{.State.Running}}' buildcache-registry 2>/dev/null)" != "true" ]; then
  docker rm -f buildcache-registry >/dev/null 2>&1 || true
  $REGISTRY_SCRIPT
fi
EOF
  chmod 0755 "$ENSURE_SCRIPT"
  cat > "$UNIT_DIR/$ENSURE_UNIT" <<EOF
[Unit]
Description=Recreate the build cache registry when the image store is empty
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=$ENSURE_SCRIPT

[Install]
WantedBy=multi-user.target
EOF

  echo "== daily cleanup of images older than ${IMAGE_MAX_AGE}"
  echo "15 3 * * * root docker image prune -a -f --filter until=${IMAGE_MAX_AGE} >/dev/null 2>&1" > "$CRON_FILE"

  stop_docker
  systemctl daemon-reload
  for p in $MOUNT_PATHS; do systemctl enable --now "$(mount_unit "$p")"; done
  for p in $MOUNT_PATHS; do
    mountpoint -q "$p" || { echo "$p is not mounted, run rollback"; exit 1; }
  done
  start_docker
  systemctl enable --now "$ENSURE_UNIT"
  for _ in $(seq 1 15); do curl -sf http://localhost:5000/v2/ >/dev/null && break; sleep 1; done
  curl -sf http://localhost:5000/v2/_catalog >/dev/null || { echo "registry is not answering on localhost:5000"; exit 1; }

  echo ""
  do_status
  echo ""
  echo "done, the image store is in RAM; the first builds pull from the registry cache"
}

do_rollback() {
  require_idle_root
  stop_runners
  stop_docker
  for p in $MOUNT_PATHS; do
    unit="$(mount_unit "$p")"
    systemctl disable --now "$unit" 2>/dev/null || true
    rm -f "$UNIT_DIR/$unit"
  done
  rm -f "$UNIT_DIR/containerd.service.d/tmpfs.conf" "$UNIT_DIR/docker.service.d/tmpfs.conf"
  rmdir "$UNIT_DIR/containerd.service.d" "$UNIT_DIR/docker.service.d" 2>/dev/null || true
  systemctl disable "$ENSURE_UNIT" 2>/dev/null || true
  rm -f "$UNIT_DIR/$ENSURE_UNIT" "$ENSURE_SCRIPT" "$CRON_FILE"
  [ -f "$DAEMON_BACKUP" ] && mv "$DAEMON_BACKUP" "$DAEMON_JSON"
  systemctl daemon-reload
  start_docker
  # the registry container of the tmpfs phase lost its rootfs with the tmpfs
  docker rm -f buildcache-registry >/dev/null 2>&1 || true
  "$SCRIPT_DIR/setup-local-registry.sh"
  echo ""
  do_status
  echo ""
  echo "done, back on the on-disk image store"
}

case "${1:-}" in
  install) do_install ;;
  rollback) do_rollback ;;
  status) do_status ;;
  *) echo "usage: $(basename "$0") {install|rollback|status}" >&2; exit 2 ;;
esac
