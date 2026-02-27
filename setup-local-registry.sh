#!/usr/bin/env bash
set -euo pipefail

REGISTRY_NAME="buildcache-registry"
REGISTRY_PORT="5000"
REGISTRY_DATA="/opt/buildcache-registry"

if docker ps --format '{{.Names}}' | grep -q "^${REGISTRY_NAME}$"; then
  echo "Registry '${REGISTRY_NAME}' is already running on port ${REGISTRY_PORT}."
  docker ps --filter "name=${REGISTRY_NAME}" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
  exit 0
fi

if docker ps -a --format '{{.Names}}' | grep -q "^${REGISTRY_NAME}$"; then
  echo "Registry '${REGISTRY_NAME}' exists but is stopped. Starting..."
  docker start "${REGISTRY_NAME}"
  exit 0
fi

echo "Creating data directory at ${REGISTRY_DATA}..."
sudo mkdir -p "${REGISTRY_DATA}"

echo "Starting local Docker registry on 127.0.0.1:${REGISTRY_PORT}..."
docker run -d \
  --name "${REGISTRY_NAME}" \
  --restart always \
  -p "127.0.0.1:${REGISTRY_PORT}:5000" \
  -v "${REGISTRY_DATA}:/var/lib/registry" \
  registry:2

echo ""
echo "Registry is running. Verify with:"
echo "  curl -s http://localhost:${REGISTRY_PORT}/v2/_catalog"
echo ""
echo "To garbage-collect unused layers:"
echo "  docker exec ${REGISTRY_NAME} bin/registry garbage-collect /etc/docker/registry/config.yml"
echo ""
echo "Consider adding a cron job for periodic cleanup, e.g.:"
echo "  0 3 * * 0 docker exec ${REGISTRY_NAME} bin/registry garbage-collect /etc/docker/registry/config.yml"
