#!/usr/bin/env bash
set -euo pipefail

SERVER_URL="${INPUT_SERVER_URL%/}"
TOKEN="${INPUT_PROJECT_TOKEN}"
ANALYSIS_ROOT="${INPUT_ANALYSIS_ROOT:-.}"
POLL_SECONDS="${INPUT_POLL_SECONDS:-5}"
TIMEOUT_SECONDS="${INPUT_TIMEOUT_SECONDS:-1800}"
WAIT_FOR_COMPLETION="${INPUT_WAIT_FOR_COMPLETION:-true}"

if [[ ! -d "$ANALYSIS_ROOT" ]]; then
  echo "analysis_root does not exist or is not a directory: $ANALYSIS_ROOT" >&2
  exit 1
fi

if [[ -z "$TOKEN" ]]; then
  echo "project_token is required" >&2
  exit 1
fi

if [[ -z "$SERVER_URL" ]]; then
  echo "server_url is required" >&2
  exit 1
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
ZIP_PATH="$WORK_DIR/workspace.zip"
MANIFEST_PATH="$WORK_DIR/manifest.json"
RESPONSE_PATH="$WORK_DIR/submit-response.json"
RUN_RESPONSE_PATH="$WORK_DIR/run-response.json"

python - <<'PY' "$ANALYSIS_ROOT" "$ZIP_PATH"
import os
import sys
import zipfile
from pathlib import Path

root = Path(sys.argv[1]).resolve()
zip_path = Path(sys.argv[2]).resolve()

with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
    for path in root.rglob("*"):
        if path.is_dir():
            continue
        rel = path.relative_to(root)
        zf.write(path, rel.as_posix())
PY

python - <<'PY' "$MANIFEST_PATH"
import json
import os
import sys

event_name = os.environ.get("GITHUB_EVENT_NAME", "")
ref_name = os.environ.get("GITHUB_REF_NAME")
repo = os.environ.get("GITHUB_REPOSITORY")
server = os.environ.get("GITHUB_SERVER_URL", "https://github.com").rstrip("/")

pull_request_number = None
commit_message = None
event_path = os.environ.get("GITHUB_EVENT_PATH")
if event_path and os.path.exists(event_path):
    with open(event_path, "r", encoding="utf-8") as f:
        payload = json.load(f)
    if event_name == "pull_request":
        pr = payload.get("pull_request", {})
        pull_request_number = pr.get("number")
    elif event_name == "push":
        head_commit = payload.get("head_commit", {})
        commit_message = head_commit.get("message")

manifest = {
    "protocol_version": 1,
    "analysis_root": os.environ.get("INPUT_ANALYSIS_ROOT", "."),
    "repository_url": f"{server}/{repo}" if repo else None,
    "repository_full_name": repo,
    "commit_sha": os.environ.get("GITHUB_SHA"),
    "commit_message": commit_message,
    "branch": ref_name,
    "pull_request_number": pull_request_number,
}

with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(manifest, f, ensure_ascii=True)
PY

curl --fail-with-body --silent --show-error \
  -X POST "$SERVER_URL/v1/analysis-requests" \
  -H "Authorization: Bearer $TOKEN" \
  -F "manifest=@${MANIFEST_PATH};type=application/json" \
  -F "source_zip=@${ZIP_PATH};type=application/zip" \
  > "$RESPONSE_PATH"

RUN_ID="$(python - <<'PY' "$RESPONSE_PATH"
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)
run_id = data.get("id")
if not run_id:
    raise SystemExit("missing run id in /v1/analysis-requests response")
print(run_id)
PY
)"

RUN_API_URL="$SERVER_URL/v1/runs/$RUN_ID"
RUN_STATUS="queued"
echo "Submitted Spec42 run: $RUN_ID"

if [[ "$WAIT_FOR_COMPLETION" == "true" ]]; then
  START_TS="$(date +%s)"
  while true; do
    curl --fail-with-body --silent --show-error \
      -H "Authorization: Bearer $TOKEN" \
      "$RUN_API_URL" \
      > "$RUN_RESPONSE_PATH"

    RUN_STATUS="$(python - <<'PY' "$RUN_RESPONSE_PATH"
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)
status = data.get("status")
if not status:
    raise SystemExit("missing status in run response")
print(status)
PY
)"

    if [[ "$RUN_STATUS" == "succeeded" ]]; then
      echo "Spec42 run succeeded: $RUN_ID"
      break
    fi
    if [[ "$RUN_STATUS" == "failed" ]]; then
      echo "Spec42 run failed: $RUN_ID" >&2
      python - <<'PY' "$RUN_RESPONSE_PATH"
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)
msg = data.get("failure_message")
if msg:
    print(f"failure_message: {msg}", file=sys.stderr)
PY
      exit 1
    fi

    NOW_TS="$(date +%s)"
    ELAPSED=$((NOW_TS - START_TS))
    if (( ELAPSED >= TIMEOUT_SECONDS )); then
      echo "Timed out waiting for Spec42 run $RUN_ID after ${TIMEOUT_SECONDS}s" >&2
      exit 1
    fi

    sleep "$POLL_SECONDS"
  done
fi

{
  echo "run_id=$RUN_ID"
  echo "run_status=$RUN_STATUS"
  echo "run_api_url=$RUN_API_URL"
} >> "$GITHUB_OUTPUT"
