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
```

## inputs

All inputs are requried to run the action

| Name                    | Type     | Description                                                                           |
|-------------------------|----------|---------------------------------------------------------------------------------------|
| `PAT`                   | String   | Personal Access Token as GitHub secret                                                |
| `NAMESPACE`             | String   | Namespace of the project                                                              |
| `NAME`                  | String   | Name of the project                                                                   |
| `ACTION_ENABLE_TESTING` | String   | if set to `true`, target `tester` in Dockerfile exist and testing will be enabeled    |

`NAMESPACE`, `NAME` and `ACTION_ENABLE_TESTING` have to be defined in GitHub as Action-Variables.
