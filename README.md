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
        uses: elan8/spec42-server-action@v1
        with:
          server_url: ${{ secrets.SPEC42_SERVER_URL }}
          project_token: ${{ secrets.SPEC42_PROJECT_TOKEN }}
          analysis_root: .
          poll_seconds: 5
          timeout_seconds: 1800
          wait_for_completion: true
          update_github_status: true
          github_token: ${{ secrets.GITHUB_TOKEN }}
          github_status_context: spec42/server

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
- `github_token` (optional): GitHub token for commit status updates
- `update_github_status` (default `false`): publish pending + final commit status on `GITHUB_SHA`
- `github_status_context` (default `spec42/server`): commit status context label

## Outputs

- `run_id`
- `run_status`
- `run_api_url`
- `github_status_state`

## Required secrets

- `SPEC42_SERVER_URL`
- `SPEC42_PROJECT_TOKEN`

If `update_github_status: true`, grant workflow permission:

```yaml
permissions:
  statuses: write
```
