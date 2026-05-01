# spec42-server-action

GitHub Action that submits code to Spec42 Server using `POST /v1/analysis-requests`.

The action:

- zips `analysis_root`
- builds an `AnalysisRequestManifest` from GitHub context
- submits `manifest + source_zip`
- optionally polls run status until `succeeded` or `failed`

## Usage

```yaml
name: Spec42 Analysis

on:
  pull_request:
  push:
    branches: [main]

jobs:
  spec42:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Submit to Spec42
        id: spec42
        uses: your-org/spec42-server-action@v1
        with:
          server_url: ${{ secrets.SPEC42_SERVER_URL }}
          project_token: ${{ secrets.SPEC42_PROJECT_TOKEN }}
          analysis_root: .
          poll_seconds: 5
          timeout_seconds: 1800
          wait_for_completion: true

      - name: Show run
        run: |
          echo "Run id: ${{ steps.spec42.outputs.run_id }}"
          echo "Run status: ${{ steps.spec42.outputs.run_status }}"
          echo "Run URL: ${{ steps.spec42.outputs.run_api_url }}"
```

## Inputs

- `server_url` (required): Spec42 Server base URL, for example `https://spec42.example.com`
- `project_token` (required): project token used as Bearer auth
- `analysis_root` (default `.`): directory to zip and analyze
- `poll_seconds` (default `5`): run status poll interval
- `timeout_seconds` (default `1800`): maximum wait time when waiting for completion
- `wait_for_completion` (default `true`): if true, action fails when run fails or times out

## Outputs

- `run_id`
- `run_status`
- `run_api_url`

## Required secrets

- `SPEC42_SERVER_URL`
- `SPEC42_PROJECT_TOKEN`
