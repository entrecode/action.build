#!/usr/bin/env bash
set -euo pipefail

# Maintenance for the local BuildKit cache registry. Replaces the older
# registry-prune-latest.sh, which kept only the "latest" tag and ran the garbage
# collector against the running registry.
#
# Two things that script got wrong and that must not come back:
#
#   * Scope tags are the live cache. action.build writes one tag per ref
#     (prod, staging, a branch name), so a pruner that keeps only "latest"
#     deletes every repository's cache every night.
#   * registry garbage-collect is not safe against concurrent writes. Its mark
#     phase does not see a blob that is uploaded while it runs, so the sweep
#     deletes it and the manifest pushed a moment later points at nothing. This
#     is why builds failed with "failed to compute cache key: short read".
#     The collector therefore only runs while the registry is stopped.
#
# Intended to run from cron, e.g. nightly:
#   30 0 * * * /usr/local/bin/maintain-local-registry.sh >> /var/log/registry-maintenance.log 2>&1

CONTAINER="${CONTAINER:-buildcache-registry}"
NAMESPACE="${NAMESPACE:-buildcache}"
REGISTRY_URL="${REGISTRY_URL:-http://localhost:5000}"
LOCKFILE="${LOCKFILE:-/tmp/registry-maintenance.lock}"
DRY_RUN="${DRY_RUN:-0}"

# Tags that are never dropped, however old they get.
PROTECTED_TAGS="${PROTECTED_TAGS:-prod staging develop}"
# Scope tags of branches nobody builds any more.
RETENTION_DAYS="${RETENTION_DAYS:-14}"
# Per-run tags. The action purges its own, these are leftovers from runs that
# were killed before their cleanup step.
RUN_TAG_HOURS="${RUN_TAG_HOURS:-6}"

log() { echo "$@"; }

# Checked explicitly: a missing flock would otherwise look exactly like a lock
# held by someone else, and maintenance would quietly never run.
command -v flock >/dev/null || { log "ERROR: flock is required but not installed"; exit 1; }

exec 9>"$LOCKFILE"
flock -n 9 || { log "another maintenance run is in progress"; exit 0; }

runner_busy() {
  pgrep -f 'Runner.Worker' >/dev/null 2>&1
}

if runner_busy; then
  log "a runner job is active, skipping this cycle"
  exit 0
fi

if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
  log "ERROR: container $CONTAINER does not exist"
  exit 1
fi

# Without this the DELETEs below answer 405 and the script would look successful.
if ! docker inspect "$CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' \
     | grep -q '^REGISTRY_STORAGE_DELETE_ENABLED=true$'; then
  log "ERROR: REGISTRY_STORAGE_DELETE_ENABLED=true missing on $CONTAINER"
  exit 1
fi

DATA_ROOT="$(docker inspect "$CONTAINER" \
  --format '{{range .Mounts}}{{if eq .Destination "/var/lib/registry"}}{{.Source}}{{end}}{{end}}')"
REPO_ROOT="$DATA_ROOT/docker/registry/v2/repositories/$NAMESPACE"
[ -d "$REPO_ROOT" ] || { log "ERROR: repo root not found: $REPO_ROOT"; exit 1; }

log "maintaining namespace $NAMESPACE in $DATA_ROOT"
log "protected tags: $PROTECTED_TAGS | scope retention: ${RETENTION_DAYS}d | run tags: ${RUN_TAG_HOURS}h"
[ "$DRY_RUN" = "1" ] && log "DRY_RUN=1, nothing is deleted"

is_protected() {
  local tag="$1" p
  for p in $PROTECTED_TAGS; do
    [ "$tag" = "$p" ] && return 0
  done
  return 1
}

tag_digest() { # <tags dir> <tag>
  local link="$1/$2/current/link"
  [ -f "$link" ] || return 0
  tr -d '\n' < "$link"
}

is_older_than() { # <tags dir> <tag> <minutes>
  local link="$1/$2/current/link"
  [ -f "$link" ] || return 1
  [ -n "$(find "$link" -maxdepth 0 -mmin "+$3" 2>/dev/null)" ]
}

deleted=0
kept_aliased=0

for repo_dir in "$REPO_ROOT"/*; do
  [ -d "$repo_dir" ] || continue
  repo="$(basename "$repo_dir")"
  tags_dir="$repo_dir/_manifests/tags"
  [ -d "$tags_dir" ] || continue

  keep_digests=""
  drop_tags=""

  for tag_dir in "$tags_dir"/*; do
    [ -d "$tag_dir" ] || continue
    tag="$(basename "$tag_dir")"
    digest="$(tag_digest "$tags_dir" "$tag")"
    [ -n "$digest" ] || continue

    stale=1
    if is_protected "$tag"; then
      stale=0
    elif [ "${tag#run-}" != "$tag" ]; then
      is_older_than "$tags_dir" "$tag" "$((RUN_TAG_HOURS * 60))" || stale=0
    else
      is_older_than "$tags_dir" "$tag" "$((RETENTION_DAYS * 1440))" || stale=0
    fi

    if [ "$stale" = "1" ]; then
      drop_tags="${drop_tags}${tag} "
    else
      keep_digests="${keep_digests}${digest} "
    fi
  done

  [ -n "$drop_tags" ] || continue
  log "== $repo =="

  for tag in $drop_tags; do
    digest="$(tag_digest "$tags_dir" "$tag")"
    [ -n "$digest" ] || continue

    # A manifest can only be deleted by digest, and that unlinks every tag
    # pointing at it. Right after a promotion the per-run tag and the scope tag
    # are the same revision, so deleting the run tag would take the live cache
    # with it.
    if [ "${keep_digests#*"$digest"}" != "$keep_digests" ]; then
      log "  keep $tag, same revision is still tagged"
      kept_aliased=$((kept_aliased + 1))
      continue
    fi

    if [ "$DRY_RUN" = "1" ]; then
      log "  [dry] delete $tag ($digest)"
    else
      code="$(curl -s -o /dev/null -w '%{http_code}' -X DELETE \
        "$REGISTRY_URL/v2/$NAMESPACE/$repo/manifests/$digest")"
      log "  delete $tag ($digest) -> $code"
    fi
    deleted=$((deleted + 1))
  done
done

log "tags removed: $deleted, kept because still tagged elsewhere: $kept_aliased"

if [ "$DRY_RUN" = "1" ]; then
  log "== garbage collection (dry run, registry stays up) =="
  docker exec "$CONTAINER" bin/registry garbage-collect -m --dry-run /etc/docker/registry/config.yml
  exit 0
fi

# Deleting the tags above took a moment. Anything that started meanwhile must
# not have the registry pulled out from under it, and the collector must not run
# next to a build. Both are avoided by simply trying again tomorrow.
if runner_busy; then
  log "a runner job started, leaving garbage collection for the next cycle"
  exit 0
fi

IMAGE="$(docker inspect "$CONTAINER" --format '{{.Config.Image}}')"

log "== stopping $CONTAINER for garbage collection =="
docker stop "$CONTAINER" >/dev/null

gc_status=0
docker run --rm --volumes-from "$CONTAINER" \
  -e REGISTRY_STORAGE_DELETE_ENABLED=true \
  "$IMAGE" bin/registry garbage-collect -m /etc/docker/registry/config.yml || gc_status=$?

log "== starting $CONTAINER =="
docker start "$CONTAINER" >/dev/null

for _ in $(seq 1 30); do
  curl -sf "$REGISTRY_URL/v2/" >/dev/null && break
  sleep 1
done

if ! curl -sf "$REGISTRY_URL/v2/" >/dev/null; then
  log "ERROR: registry did not come back up"
  exit 1
fi

[ "$gc_status" = "0" ] || { log "ERROR: garbage collection failed with $gc_status"; exit "$gc_status"; }
log "done, registry is back up"
