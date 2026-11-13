#!/usr/bin/env bash
set -euo pipefail

# Switches a self-hosted runner host to the containerd image store, which lets
# action.build use the docker driver (layers stay local, --load is free).
#
# Run as root while no job is active. Runner services are stopped for the
# switch, queued jobs wait in GitHub and start once the runners are back.
#
# Images and containers of the old store become invisible after the switch,
# so leftovers are removed first and the cache registry is recreated after.
# Volumes, including buildcache-registry-data, are not affected.
#
# Rollback: restore the backup of daemon.json printed below and restart docker.
# The old store comes back unchanged.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DAEMON_JSON="/etc/docker/daemon.json"

uses_containerd_store() {
  docker info --format '{{json .DriverStatus}}' | grep -q 'io.containerd.snapshotter'
}

[ "$(id -u)" = "0" ] || { echo "run as root"; exit 1; }
command -v jq >/dev/null || { echo "jq is required"; exit 1; }

if uses_containerd_store; then
  echo "already on the containerd image store, nothing to do"
  exit 0
fi

if pgrep -f 'Runner.Worker' >/dev/null; then
  echo "a runner job is active, try again when the runners are idle"
  exit 1
fi

RUNNERS="$(systemctl list-units --type=service --state=running --no-legend --plain 'actions.runner.*' | awk '{print $1}')"
echo "== stopping runners: ${RUNNERS:-none}"
for unit in $RUNNERS; do systemctl stop "$unit"; done
trap 'echo "== starting runners"; for unit in $RUNNERS; do systemctl start "$unit"; done' EXIT

echo "== removing leftover buildx builders"
docker ps -aq --filter 'name=buildx_buildkit_' | xargs -r docker rm -f
docker volume ls -q --filter 'name=buildx_buildkit_' | xargs -r docker volume rm

echo "== removing unused images of the old store"
docker image prune -a -f

BACKUP="${DAEMON_JSON}.$(date +%Y%m%d%H%M%S).bak"
[ -f "$DAEMON_JSON" ] || echo '{}' > "$DAEMON_JSON"
cp "$DAEMON_JSON" "$BACKUP"
jq '.features["containerd-snapshotter"] = true' "$BACKUP" > "$DAEMON_JSON"
echo "== daemon.json updated, backup at ${BACKUP}"

echo "== restarting docker"
systemctl restart docker
for _ in $(seq 1 60); do docker info >/dev/null 2>&1 && break; sleep 1; done

if ! uses_containerd_store; then
  echo "docker did not come up on the containerd store, restoring ${BACKUP}"
  cp "$BACKUP" "$DAEMON_JSON"
  systemctl restart docker
  exit 1
fi

echo "== recreating the cache registry"
"${SCRIPT_DIR}/setup-local-registry.sh"
for _ in $(seq 1 15); do curl -sf http://localhost:5000/v2/ >/dev/null && break; sleep 1; done
curl -sf http://localhost:5000/v2/_catalog >/dev/null || { echo "registry is not answering on localhost:5000"; exit 1; }

if crontab -l 2>/dev/null | grep -q 'docker system prune -a'; then
  echo ""
  echo "WARNING: root's crontab runs 'docker system prune -a', which now deletes the"
  echo "whole build cache. Replace it with:"
  echo "  0 2 * * 1 docker builder prune -f --max-used-space 50gb && docker image prune -a -f --filter until=168h"
fi

echo ""
echo "done, docker now uses the containerd image store"
