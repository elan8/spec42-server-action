# spec42-server-action

GitHub Action that submits code to Spec42 Server using `POST /v1/analysis-requests`.

The action:

- zips `analysis_root`
- builds an `AnalysisRequestManifest` from GitHub context
- submits `manifest + source_zip`
- optionally polls run status until `succeeded` or `failed`
- optionally fetches a GitHub-ready Spec42 PR summary Markdown file

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

To fetch a PR summary Markdown file, pass the explicit base run id and enable
`generate_pr_summary`:

```yaml
      - name: Submit to Spec42
        id: spec42
        uses: elan8/spec42-server-action@v1
        with:
          server_url: ${{ secrets.SPEC42_SERVER_URL }}
          project_token: ${{ secrets.SPEC42_PROJECT_TOKEN }}
          analysis_root: .
          wait_for_completion: true
          base_run_id: ${{ vars.SPEC42_BASE_RUN_ID }}
          generate_pr_summary: true
          public_base_url: ${{ secrets.SPEC42_PUBLIC_BASE_URL }}

      - name: Post Spec42 PR summary
        if: github.event_name == 'pull_request'
        env:
          GH_TOKEN: ${{ github.token }}
          PR_SUMMARY_PATH: ${{ steps.spec42.outputs.pr_summary_path }}
        run: gh pr comment "${{ github.event.pull_request.number }}" --body-file "$PR_SUMMARY_PATH"
```

## Inputs

- `server_url` (required): Spec42 Server base URL, for example `https://spec42.example.com`
- `project_token` (required): project token used as Bearer auth
- `analysis_root` (default `.`): directory to zip and analyze
- `poll_seconds` (default `5`): run status poll interval
- `timeout_seconds` (default `1800`): maximum wait time when waiting for completion
- `wait_for_completion` (default `true`): if true, action fails when run fails or times out
- `base_run_id` (optional): explicit base Spec42 run id used when generating a PR summary
- `generate_pr_summary` (default `false`): fetch the PR summary Markdown file after the head run succeeds
- `public_base_url` (optional): externally reachable Spec42 Server URL for links in the PR summary; defaults to `server_url`
- `pr_summary_path` (optional): path where the PR summary Markdown should be written
- `github_token` (optional): GitHub token for commit status updates
- `update_github_status` (default `false`): publish pending + final commit status on `GITHUB_SHA`
- `github_status_context` (default `spec42/server`): commit status context label

## Outputs

- `run_id`
- `run_status`
- `run_api_url`
- `pr_summary_path`
- `pr_summary_api_url`
- `github_status_state`

## Required secrets

- `SPEC42_SERVER_URL`
- `SPEC42_PROJECT_TOKEN`

If `update_github_status: true`, grant workflow permission:

```yaml
permissions:
  statuses: write
```

If the workflow posts PR comments with `gh pr comment`, also grant:

```yaml
permissions:
  pull-requests: write
```
