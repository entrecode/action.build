# Runbook: broken build cache

For the local BuildKit cache registry on the self-hosted runner. GitHub-hosted
runners use `type=gha` and are not affected.

## Symptom

A build fails after a few seconds, during or shortly after the cache import:

```
#5 importing cache manifest from localhost:5000/buildcache/<ns>.<name>-tester
#14 [tester 2/10] COPY --chown=node:node ./src ./src
#14 ERROR: short read: expected 447 bytes but got 0: unexpected EOF
ERROR: failed to solve: failed to compute cache key: short read: ...
```

Other wordings for the same class of problem: `blob unknown to registry`,
`content digest mismatch`, `failed to configure registry cache importer`.

A quick build that fails in well under a minute is a cache problem. A build that
runs for several minutes and then fails is a real build or test failure — this
runbook does not apply.

Since the pre-flight check landed the action should catch this by itself and log
`::warning:: build cache … is corrupt and was skipped`. If a build still dies
this way, the check has a gap and the details below are worth capturing before
anything is deleted.

## 1. Unblock the release

Deleting the affected scope tag is enough, the next build repopulates it:

```bash
NS=hec; NAME=dsb-layer; SCOPE=prod     # prod for tags, staging for release/*, else the branch
for TARGET in tester runner; do
  REPO="buildcache/${NS}.${NAME}-${TARGET}"
  D=$(curl -sI -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
        "http://localhost:5000/v2/${REPO}/manifests/${SCOPE}" \
      | tr -d '\r' | awk 'tolower($1)=="docker-content-digest:"{print $2}')
  [ -n "$D" ] && curl -s -o /dev/null -w "${REPO}:${SCOPE} -> %{http_code}\n" \
    -X DELETE "http://localhost:5000/v2/${REPO}/manifests/${D}"
done
```

Then re-run the workflow. Expect a cold build (~14 min instead of ~30 s).

Do **not** run `garbage-collect` to fix this. It is not needed to unblock a
build and, against a running registry, it is what creates the problem.

## 2. Capture evidence first, if there is time

The interesting state disappears once the tags are deleted.

```bash
# which blobs the broken manifest references, and which one is bad
scripts/buildcache.sh verify buildcache/hec.dsb-layer-tester prod

# empty blob files on disk
docker exec buildcache-registry sh -c \
  'find /var/lib/registry/docker/registry/v2/blobs -name data -size 0'

# what else was building at the time
gh run list --repo entrecode/<repo> --limit 30 \
  --json databaseId,headBranch,createdAt,updatedAt,conclusion
```

A `HEAD` on a blob is not proof of health: the registry answers it from its own
metadata, so a file that is empty on disk still reports the full
`Content-Length`. Only reading the bytes back shows it, which is what
`buildcache.sh verify` does.

## 3. Find out why

Two causes have actually occurred:

**Concurrent builds sharing one cache tag.** A workflow's `concurrency` group is
normally per ref, so `develop`, `release/*` and a tag build in parallel. Before
scoped tags they all wrote the same cache ref and one run could publish a
manifest referencing blobs another run had not finished uploading. Check whether
two runs of the same repository overlapped. Fixed by one scope per ref plus
publish-on-success; if it reappears, the scopes are not separating what you
think they are.

**Garbage collection against the running registry.** `registry garbage-collect`
has no locking. A blob uploaded between its mark and sweep phases counts as
unreferenced and is deleted, and the manifest that arrives a moment later points
at nothing. Check for cron jobs:

```bash
crontab -l; sudo crontab -l
systemctl list-timers --all | grep -iE 'registry|garbage'
grep -i 'deleting blob' /var/log/registry-maintenance.log | tail
```

Only `maintain-local-registry.sh` should be doing this, and only with the
registry stopped.

## 4. What must be true on the runner

- `setup-local-registry.sh` describes the intended container. Running it against
  an existing registry reports drift instead of changing anything.
- `maintain-local-registry.sh` is the only thing that deletes from the registry.
  It skips itself while a runner job is active and stops the registry before
  collecting.
- No `docker volume prune -a` in any crontab. With `-a` it removes named volumes
  that no running container holds, so it deletes `buildcache-registry-data` the
  moment the registry is stopped — for example during maintenance.
- Any cleanup must keep the scope tags (`prod`, `staging`, branch names). A
  pruner that keeps only `latest` empties every repository's cache nightly.
