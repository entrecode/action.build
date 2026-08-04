#!/usr/bin/env bash
set -euo pipefail

REGISTRY_NAME="buildcache-registry"
REGISTRY_PORT="5000"
REGISTRY_VOLUME="buildcache-registry-data"
REGISTRY_IMAGE="registry:2"

# Required by maintain-local-registry.sh, which deletes stale tags through the
# API. Without it every DELETE answers 405 and the cleanup silently does nothing.
DELETE_ENABLED="REGISTRY_STORAGE_DELETE_ENABLED=true"
# Cancelled pushes leave partial uploads behind. The default is 168h.
UPLOAD_PURGING="REGISTRY_STORAGE_MAINTENANCE_UPLOADPURGING_AGE=24h"

check_drift() {
  local drift=0

  if ! docker inspect "${REGISTRY_NAME}" \
       --format '{{range .Mounts}}{{.Name}}{{end}}' | grep -q "^${REGISTRY_VOLUME}$"; then
    echo "  WARNING: not backed by volume '${REGISTRY_VOLUME}':"
    docker inspect "${REGISTRY_NAME}" --format '{{range .Mounts}}    {{.Type}} {{.Source}} -> {{.Destination}}{{end}}'
    drift=1
  fi

  local env_var
  for env_var in "${DELETE_ENABLED}" "${UPLOAD_PURGING}"; do
    if ! docker inspect "${REGISTRY_NAME}" \
         --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -q "^${env_var}$"; then
      echo "  WARNING: ${env_var} is not set"
      drift=1
    fi
  done

  if [ "$drift" = "1" ]; then
    echo ""
    echo "  The running registry does not match this script. Recreate it with:"
    echo "    docker rm -f ${REGISTRY_NAME} && $0"
    echo "  The volume '${REGISTRY_VOLUME}' survives that, only the cache metadata"
    echo "  in the container is rebuilt."
  fi
}

if docker ps --format '{{.Names}}' | grep -q "^${REGISTRY_NAME}$"; then
  echo "Registry '${REGISTRY_NAME}' is already running on port ${REGISTRY_PORT}."
  docker ps --filter "name=${REGISTRY_NAME}" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
  check_drift
  exit 0
fi

if docker ps -a --format '{{.Names}}' | grep -q "^${REGISTRY_NAME}$"; then
  echo "Registry '${REGISTRY_NAME}' exists but is stopped. Starting..."
  docker start "${REGISTRY_NAME}"
  check_drift
  exit 0
fi

echo "Starting local Docker registry on 127.0.0.1:${REGISTRY_PORT}..."
docker volume create "${REGISTRY_VOLUME}" >/dev/null
docker run -d \
  --name "${REGISTRY_NAME}" \
  --restart always \
  -p "127.0.0.1:${REGISTRY_PORT}:5000" \
  -v "${REGISTRY_VOLUME}:/var/lib/registry" \
  -e "${DELETE_ENABLED}" \
  -e "${UPLOAD_PURGING}" \
  "${REGISTRY_IMAGE}"

echo ""
echo "Registry is running. Verify with:"
echo "  curl -s http://localhost:${REGISTRY_PORT}/v2/_catalog"
echo ""
echo "For cleanup use maintain-local-registry.sh. Do NOT run garbage-collect"
echo "against the running registry: its mark phase misses blobs that are"
echo "uploaded while it works, the sweep deletes them, and every following build"
echo "fails with 'failed to compute cache key: short read'."
echo ""
echo "  install -m 0755 maintain-local-registry.sh /usr/local/bin/"
echo "  # nightly, skips itself while a runner job is active:"
echo "  30 0 * * * /usr/local/bin/maintain-local-registry.sh >> /var/log/registry-maintenance.log 2>&1"
echo ""
echo "Also make sure no other cron job can take the cache down, in particular"
echo "'docker volume prune -a', which removes ${REGISTRY_VOLUME} whenever this"
echo "container happens to be stopped."
