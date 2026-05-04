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
          github_token: ${{ github.token }}
          github_status_context: spec42/server

      - name: Show run
        run: |
          echo "Run id: ${{ steps.spec42.outputs.run_id }}"
          echo "Run status: ${{ steps.spec42.outputs.run_status }}"
          echo "Run URL: ${{ steps.spec42.outputs.run_api_url }}"
```

For the normal pull request workflow, enable PR summary generation and comment
posting. The action resolves the latest successful run for the PR base branch and
updates the same Spec42 comment on subsequent runs:

```yaml
permissions:
  statuses: write
  pull-requests: write

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
          wait_for_completion: true
          update_github_status: true
          github_token: ${{ github.token }}
          generate_pr_summary: true
          public_base_url: ${{ secrets.SPEC42_PUBLIC_BASE_URL }}
          post_pr_comment: true
```

For deterministic or manual workflows, pass `base_run_id` explicitly. If
`base_run_id` is omitted, the action uses `pull_request.base.ref`; override that
with `base_branch` when needed.

## Inputs

- `server_url` (required): Spec42 Server base URL, for example `https://spec42.example.com`
- `project_token` (required): project token used as Bearer auth
- `analysis_root` (default `.`): directory to zip and analyze
- `poll_seconds` (default `5`): run status poll interval
- `timeout_seconds` (default `1800`): maximum wait time when waiting for completion
- `wait_for_completion` (default `true`): if true, action fails when run fails or times out
- `base_run_id` (optional): explicit base Spec42 run id used when generating a PR summary
- `base_branch` (optional): base branch for automatic base run lookup; defaults to `pull_request.base.ref`
- `generate_pr_summary` (default `false`): fetch the PR summary Markdown file after the head run succeeds
- `post_pr_comment` (default `false`): create or update a GitHub PR comment with the generated summary
- `pr_comment_marker` (default `<!-- spec42-pr-summary -->`): hidden marker used to find the existing Spec42 comment
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
- `base_run_id`
- `pr_comment_url`
- `pr_comment_action`
- `github_status_state`

## Required secrets

- `SPEC42_SERVER_URL`
- `SPEC42_PROJECT_TOKEN`

If `update_github_status: true`, grant workflow permission:

```yaml
permissions:
  statuses: write
```

Status publishing is best-effort. If GitHub rejects the status update, for
example on a restricted fork workflow token, the action warns and continues the
Spec42 analysis run.

If `post_pr_comment: true`, also grant:

```yaml
permissions:
  pull-requests: write
```
