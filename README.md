# action.build

GitHub composite Action to build and push image to ghcr. Newest version: v17, latest tag = v15

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



`PAT` and `LOCAL_TESTING_SECRET` can be set in GitHub as Action-Secrets.
`NAMESPACE`, `NAME`, `ACTION_ENABLE_TESTING`, `ACTIVATE_DEV_RUNNER`, `WORKING_DIRECTORY` can be set in GitHub as Action-Variables.
