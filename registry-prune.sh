#!/usr/bin/env bash
set -euo pipefail

CONTAINER="${CONTAINER:-buildcache-registry}"
NAMESPACE="${NAMESPACE:-buildcache}"
REGISTRY_URL="${REGISTRY_URL:-http://localhost:5000}"
LOCKFILE="${LOCKFILE:-/tmp/registry-prune.lock}"
DRY_RUN="${DRY_RUN:-0}"

exec 9>"$LOCKFILE"
flock -n 9 || { echo "Another prune is running"; exit 1; }

DATA_ROOT="$(docker inspect "$CONTAINER" --format '{{range .Mounts}}{{if eq .Destination "/var/lib/registry"}}{{.Source}}{{end}}{{end}}')"
REPO_ROOT="$DATA_ROOT/docker/registry/v2/repositories/$NAMESPACE"

[ -d "$REPO_ROOT" ] || { echo "Repo root not found: $REPO_ROOT"; exit 1; }

# Ensure delete API is enabled, otherwise DELETEs return 405 and script looks successful
if ! docker inspect "$CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' \
     | grep -q '^REGISTRY_STORAGE_DELETE_ENABLED=true$'; then
  echo "ERROR: REGISTRY_STORAGE_DELETE_ENABLED=true missing on $CONTAINER"
  exit 1
fi

echo "Pruning namespace: $NAMESPACE"
echo "Repo root: $REPO_ROOT"
[ "$DRY_RUN" = "1" ] && echo "DRY_RUN=1 (no DELETE, no GC)"

delete_manifest() {
  local repo="$1" digest="$2" label="$3"
  if [ "$DRY_RUN" = "1" ]; then
    echo "  [dry] del $label digest=sha256:$digest"
    return
  fi
  local code
  code="$(curl -s -o /dev/null -w "%{http_code}" -X DELETE \
    "$REGISTRY_URL/v2/$NAMESPACE/$repo/manifests/sha256:$digest")"
  echo "  del $label digest=sha256:$digest -> $code"
}

for repo_dir in "$REPO_ROOT"/*; do
  [ -d "$repo_dir" ] || continue
  repo="$(basename "$repo_dir")"
  tags_dir="$repo_dir/_manifests/tags"

  [ -d "$tags_dir" ] || continue
  echo "== repo: $repo =="

  # 1) Delete all manifests referenced by non-latest tags
  for tag_dir in "$tags_dir"/*; do
    [ -d "$tag_dir" ] || continue
    tag="$(basename "$tag_dir")"
    [ "$tag" = "latest" ] && continue

    idx="$tag_dir/index/sha256"
    [ -d "$idx" ] || continue
    for dg in $(ls -1 "$idx" 2>/dev/null || true); do
      delete_manifest "$repo" "$dg" "tag=$tag"
    done
  done

  # 2) Keep only the current latest revision (source of truth: tags/latest/current/link)
  latest_idx="$tags_dir/latest/index/sha256"
  latest_current_link="$tags_dir/latest/current/link"
  if [ -d "$latest_idx" ] && [ -f "$latest_current_link" ]; then
    latest_current="$(sed 's/^sha256://' "$latest_current_link")"
    if [ -z "$latest_current" ]; then
      echo "  WARN: empty current link for latest in $repo, skipping old-latest cleanup"
    else
      for dg in $(ls -1 "$latest_idx" 2>/dev/null || true); do
        [ "$dg" = "$latest_current" ] && continue
        delete_manifest "$repo" "$dg" "old latest"
      done
    fi
  fi
done

# 3) GC with --delete-untagged to also collect orphaned manifests
#    (buildx cache pushes leave digest-only manifests not referenced by any tag).
if [ "$DRY_RUN" = "1" ]; then
  echo "== GC (dry-run) =="
  docker exec "$CONTAINER" bin/registry garbage-collect -m --dry-run /etc/docker/registry/config.yml
else
  echo "== GC =="
  docker exec "$CONTAINER" bin/registry garbage-collect -m /etc/docker/registry/config.yml
fi
