# action.build

GitHub composite Action to build and push image to ghcr

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

    steps:
    - name: build and push action
      id: build-action
      uses: entrecode/action.build@latest
      with:
        NAMESPACE: ${{ vars.NAMESPACE }}
        NAME: ${{ vars.NAME }}
        PAT: ${{ secrets.PAT }}
        ACTION_ENABLE_TESTING: ${{ vars.ACTION_ENABLE_TESTING }} # optional when false
        LOCAL_TESTING_SECRET: ${{ secrets.LOCAL_TESTING_SECRET }} # optional when no local-testing.yaml is needed for running tests
```

## inputs

All inputs are requried to run the action

| Name                    | Type        | Description                                                                                 |
|-------------------------|-------------|---------------------------------------------------------------------------------------------|
| `PAT`                   | String      | Personal Access Token as GitHub secret                                                      |
| `NAMESPACE`             | String      | Namespace of the project                                                                    |
| `NAME`                  | String      | Name of the project                                                                         |
| `ACTION_ENABLE_TESTING` | String      | if set to `true`, target `tester` in Dockerfile exist and testing will be enabeled          |
| `LOCAL_TESTING_SECRET`  | yaml-format | containes local-testing.yaml secrets, necessary if secrets are needed for running the tests |


`PAT` and `LOCAL_TESTING_SECRET` are defined in GitHub as Action-Secrets.
`NAMESPACE`, `NAME` and `ACTION_ENABLE_TESTING` are defined in GitHub as Action-Variables.
