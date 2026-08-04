# action.build

GitHub composite Action to build and push image to ghcr. Newest version: v26, latest tag = v24

## example

```yaml
build:
    runs-on: ubuntu-latest

    permissions:
      contents: read
      packages: write

    outputs:
      env: ${{ steps.build-action.outputs.env }}
      version: ${{ steps.build-action.outputs.version }}


    # Services section, only needed if you want to run tests which require a database
    services:
      postgres:
        image: postgres:11
        env:
          POSTGRES_PASSWORD: password
        ports:
          - 5432
        options: >-
          --health-cmd pg_isready
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5
          --health-start-period 30s

    steps:
    - name: build and push action
      id: build-action
      uses: entrecode/action.build@latest # @v6 if you want to use the WORKING_DIRECTORY
      with:
        PAT: ${{ secrets.PAT }}
        NAMESPACE: ${{ vars.NAMESPACE }}
        NAME: ${{ vars.NAME }}
        GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        ACTION_ENABLE_TESTING: ${{ vars.ACTION_ENABLE_TESTING }}
        LOCAL_TESTING_SECRET: ${{ secrets.LOCAL_TESTING_SECRET }}
        ACTIVATE_DEV_RUNNER: ${{ vars.ACTIVATE_DEV_RUNNER }}
        WORKING_DIRECTORY: ${{ vars.WORKING_DIRECTORY }} # only available in v6 until now
        # necessary if tests need a Database to be executed - in combination with the services from above
        DBPORT: ${{ job.services.postgres.ports['5432'] }}

```

## inputs


| Name                    | Type        | Description                                                                                 | Required  | Version      |
|-------------------------|-------------|---------------------------------------------------------------------------------------------|-----------|--------------|
| `PAT`                   | String      | Personal Access Token as GitHub secret                                                      | Yes       | latest (v4)  |
| `NAMESPACE`             | String      | Namespace of the project                                                                    | Yes       | latest (v4)  |
| `NAME`                  | String      | Name of the project                                                                         | Yes       | latest (v4)  |
| `GITHUB_TOKEN`          | String      | GITHUB_TOKEN for authentication                                                             | Yes       | latest (v4)  |
| `ACTION_ENABLE_TESTING` | String      | if set to `true`, target `tester` in Dockerfile exist and testing will be enabeled          | No        | latest (v4)  |
| `LOCAL_TESTING_SECRET`  | yaml-format | containes local-testing.yaml secrets, necessary if secrets are needed for running the tests | No        | latest (v4)  |
| `ACTIVATE_DEV_RUNNER`   | String      | if set to `true`, container with target `devRunner` in Dockerfile will be created           | No        | latest (v4)  |
| `WORKING_DIRECTORY`     | String      | Working directory path, e.g. `./apps/app1`, default is `.`                                  | No        | latest (v6)  |
| `DBPORT`                | String      | Random generated database port to avoid port collision in stage and production action       | No        | latest (v11) |
| `DOCKERFILE`            | String      | Path to the Dockerfile, default is `Dockerfile`                                             | No        | latest (v15) |
| `DOCKER_CONTEXT`        | String      | Path to the Docker context, default is `.`                                                  | No        | latest (v15) |
| `OVERWRITE_BUILD_TASK`  | String      | Overwrite the build task in the Dockerfile, e.g. `build:dev`                                | No        | latest (v17) |
| `CACHE_SCOPE`           | String      | Overrides the build cache scope, see below. Leave unset unless you know you need it         | No        | v26          |



`PAT` and `LOCAL_TESTING_SECRET` can be set in GitHub as Action-Secrets.
`NAMESPACE`, `NAME`, `ACTION_ENABLE_TESTING`, `ACTIVATE_DEV_RUNNER`, `WORKING_DIRECTORY` can be set in GitHub as Action-Variables.

## build cache

On self-hosted runners the BuildKit cache lives in a local registry on
`localhost:5000` (see `setup-local-registry.sh`). On GitHub-hosted runners
`type=gha` is used and none of the following applies.

**Scopes.** Every ref gets its own cache tag: `prod` for tags, `staging` for
`release/*`, otherwise the branch name. `cache-from` reads the own scope first
and falls back to `develop`, so a new branch still starts warm. Set
`CACHE_SCOPE` to override.

This matters because a workflow's `concurrency` group is usually per ref, so
builds of `develop`, `release/*` and a tag run *in parallel*. Sharing one cache
tag meant one run could publish a manifest pointing at blobs another run had not
finished uploading. The result was a cache that failed every following build
with `failed to compute cache key: short read ... unexpected EOF` until it was
deleted by hand.

**Pre-flight check.** Before the build, every candidate ref is verified and only
the healthy ones are passed to buildx. A missing ref is normal on a new scope. A
corrupt one is not — it imports without complaint and only kills the build
seconds later when a blob turns out to be unreadable, which is what used to
block releases. Such a ref is now skipped with a warning, so the build falls
back to a cache miss instead of failing.

**Publish on success.** Builds export to a throwaway tag
`run-<run_id>-<attempt>`. Only after the build succeeded is that tag verified
(every referenced blob must exist *and* its last byte must be readable — a
truncated blob still reports the correct `Content-Length` on `HEAD`) and then
published onto the scope tag. A cancelled or failed run therefore never
publishes. Leftover run tags are purged in a final step and by the registry's
garbage collection.

A failed promotion never fails the build. It only costs the next build its cache.

**Runner prerequisite.** `maintain-local-registry.sh` must be the only thing
deleting from the registry — it skips itself while a runner job is active and
stops the registry before collecting garbage. Any other pruner has to keep the
scope tags (`prod`, `staging`, branch names); one that keeps just `latest`
deletes the entire cache every night.

See [RUNBOOK.md](RUNBOOK.md) when a build fails with
`failed to compute cache key: short read`.
