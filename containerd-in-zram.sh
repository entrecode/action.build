#!/usr/bin/env bash
set -euo pipefail

# Keeps the containerd image store and the BuildKit state of a self-hosted
# runner host in RAM: an ext4 filesystem on a zram device. Builds unpack and
# write layers to memory instead of the SSDs. Volumes, including
# buildcache-registry-data, stay on disk; after a reboot the store is empty and
# the first builds pull from the registry cache.
#
# ext4 and not tmpfs: on kernels before 6.6 tmpfs has no user.* xattrs, so
# containerd's overlay differ fails on every layer and its fallback can
# collide with itself ("ref ... locked ... unavailable").
#
#   containerd-in-zram.sh install    create the zram store, limit the build cache, restart docker
#   containerd-in-zram.sh rollback   back to the on-disk store, which the mounts only hid
#   containerd-in-zram.sh status
#
# Requires the containerd image store (migrate-to-containerd-store.sh). Run as
# root while no job is active; runner services are stopped meanwhile.

DISK_SIZE="${DISK_SIZE:-80G}"
MEM_LIMIT="${MEM_LIMIT:-60G}"
JOB_RESERVE="${JOB_RESERVE:-16G}"
GC_MAX_USED="${GC_MAX_USED:-35GB}"
GC_MIN_FREE="${GC_MIN_FREE:-15GB}"
IMAGE_MAX_AGE="${IMAGE_MAX_AGE:-48h}"
ZRAM_SYSFS="${ZRAM_SYSFS:-/sys/block}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DAEMON_JSON="/etc/docker/daemon.json"
DAEMON_BACKUP="/etc/docker/daemon.json.before-zram"
UNIT_DIR="/etc/systemd/system"
STORE_UNIT="zram-docker-store.service"
STORE_SCRIPT="/usr/local/sbin/zram-docker-store.sh"
ENSURE_UNIT="buildcache-registry-ensure.service"
ENSURE_SCRIPT="/usr/local/sbin/ensure-buildcache-registry.sh"
REGISTRY_SCRIPT="/usr/local/sbin/setup-local-registry.sh"
CRON_FILE="/etc/cron.d/buildcache-zram"
DROPIN="zram.conf"

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
  # all enabled runners, not just running ones: a run aborted earlier may have left them stopped
  RUNNERS="$(systemctl list-unit-files --type=service --state=enabled --no-legend --plain 'actions.runner.*' | awk '{print $1}')"
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

recreate_registry() {
  # a registry container from the other store has no rootfs here
  docker rm -f buildcache-registry >/dev/null 2>&1 || true
  "$SCRIPT_DIR/setup-local-registry.sh"
  for _ in $(seq 1 15); do curl -sf http://localhost:5000/v2/ >/dev/null && return 0; sleep 1; done
  echo "registry is not answering on localhost:5000"
  return 1
}

do_status() {
  if systemctl is-active --quiet "$STORE_UNIT"; then
    zramctl --output NAME,ALGORITHM,DISKSIZE,DATA,COMPR,TOTAL,MOUNTPOINT 2>/dev/null || true
    df -h --output=target,size,used,avail /var/lib/docker-ram | tail -1
  else
    echo "image store on disk"
  fi
  docker info --format 'store: {{.Driver}} {{json .DriverStatus}}'
  docker buildx inspect default 2>/dev/null | grep -iE 'max used|min free|reserved' | sort -u || true
  docker ps --filter name=buildcache-registry --format 'registry: {{.Status}}'
}

write_store_script() {
  cat > "$STORE_SCRIPT" <<EOF
#!/usr/bin/env bash
set -euo pipefail
# ext4 on zram for /var/lib/containerd and /var/lib/docker/buildkit, recreated on every start
ROOT=/var/lib/docker-ram
STATE=/run/zram-docker-store.dev
case "\${1:-}" in
  start)
    modprobe zram
    dev=\$(zramctl --find --size $DISK_SIZE --algorithm lz4)
    echo "\$dev" > "\$STATE"
    echo $MEM_LIMIT > "$ZRAM_SYSFS/\$(basename "\$dev")/mem_limit"
    mkfs.ext4 -q -F "\$dev"
    mkdir -p "\$ROOT" /var/lib/containerd /var/lib/docker/buildkit
    mount -o discard,noatime "\$dev" "\$ROOT"
    mkdir -p "\$ROOT/containerd" "\$ROOT/buildkit"
    chmod 0711 "\$ROOT/containerd" "\$ROOT/buildkit"
    mount --bind "\$ROOT/containerd" /var/lib/containerd
    mount --bind "\$ROOT/buildkit" /var/lib/docker/buildkit
    ;;
  stop)
    umount /var/lib/docker/buildkit /var/lib/containerd "\$ROOT" 2>/dev/null || true
    [ -f "\$STATE" ] && zramctl --reset "\$(cat "\$STATE")" && rm -f "\$STATE"
    ;;
  *) echo "usage: \$0 {start|stop}" >&2; exit 2 ;;
esac
EOF
  chmod 0755 "$STORE_SCRIPT"
}

do_install() {
  require_idle_root
  for cmd in jq zramctl mkfs.ext4 modprobe numfmt; do
    command -v "$cmd" >/dev/null || { echo "$cmd is required"; exit 1; }
  done
  docker info --format '{{json .DriverStatus}}' | grep -q 'io.containerd.snapshotter' \
    || { echo "the containerd image store is not active, run migrate-to-containerd-store.sh first"; exit 1; }
  if systemctl is-active --quiet "$STORE_UNIT"; then
    echo "already in zram"; do_status; exit 0
  fi
  if mountpoint -q /var/lib/containerd; then
    echo "/var/lib/containerd is already a mountpoint (tmpfs leftover?), clean that up first"; exit 1
  fi
  avail_kb=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
  need_kb=$(( ($(numfmt --from=iec "$MEM_LIMIT") + $(numfmt --from=iec "$JOB_RESERVE")) / 1024 ))
  [ "$avail_kb" -gt "$need_kb" ] || { echo "not enough free memory for ${MEM_LIMIT} of zram plus ${JOB_RESERVE} for jobs"; exit 1; }

  stop_runners

  echo "== writing the zram store service"
  write_store_script
  cat > "$UNIT_DIR/$STORE_UNIT" <<EOF
[Unit]
Description=ext4 on zram for the containerd image store (action.build)
DefaultDependencies=no
After=local-fs.target
Before=containerd.service docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$STORE_SCRIPT start
ExecStop=$STORE_SCRIPT stop

[Install]
WantedBy=multi-user.target
EOF
  for svc in containerd docker; do
    mkdir -p "$UNIT_DIR/$svc.service.d"
    printf '[Unit]\nRequires=%s\nAfter=%s\n' "$STORE_UNIT" "$STORE_UNIT" > "$UNIT_DIR/$svc.service.d/$DROPIN"
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
  systemctl enable --now "$STORE_UNIT"
  for p in /var/lib/docker-ram /var/lib/containerd /var/lib/docker/buildkit; do
    mountpoint -q "$p" || { echo "$p is not mounted, run rollback"; exit 1; }
  done
  start_docker
  recreate_registry
  systemctl enable "$ENSURE_UNIT"

  echo ""
  do_status
  echo ""
  echo "done, the image store is in zram; the first builds pull from the registry cache"
}

do_rollback() {
  require_idle_root
  stop_runners
  stop_docker
  systemctl disable --now "$STORE_UNIT" 2>/dev/null || true
  rm -f "$UNIT_DIR/$STORE_UNIT" "$STORE_SCRIPT"
  for svc in containerd docker; do
    rm -f "$UNIT_DIR/$svc.service.d/$DROPIN"
    rmdir "$UNIT_DIR/$svc.service.d" 2>/dev/null || true
  done
  systemctl disable "$ENSURE_UNIT" 2>/dev/null || true
  rm -f "$UNIT_DIR/$ENSURE_UNIT" "$ENSURE_SCRIPT" "$CRON_FILE"
  if [ -f "$DAEMON_BACKUP" ]; then mv "$DAEMON_BACKUP" "$DAEMON_JSON"; fi
  systemctl daemon-reload
  start_docker
  recreate_registry
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
