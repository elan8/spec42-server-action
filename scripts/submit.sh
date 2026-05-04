#!/usr/bin/env bash
set -euo pipefail

SERVER_URL="${INPUT_SERVER_URL%/}"
TOKEN="${INPUT_PROJECT_TOKEN}"
ANALYSIS_ROOT="${INPUT_ANALYSIS_ROOT:-.}"
POLL_SECONDS="${INPUT_POLL_SECONDS:-5}"
TIMEOUT_SECONDS="${INPUT_TIMEOUT_SECONDS:-1800}"
WAIT_FOR_COMPLETION="${INPUT_WAIT_FOR_COMPLETION:-true}"
BASE_RUN_ID="${INPUT_BASE_RUN_ID:-}"
BASE_BRANCH="${INPUT_BASE_BRANCH:-}"
GENERATE_PR_SUMMARY="${INPUT_GENERATE_PR_SUMMARY:-false}"
POST_PR_COMMENT="${INPUT_POST_PR_COMMENT:-false}"
PR_COMMENT_MARKER="${INPUT_PR_COMMENT_MARKER:-<!-- spec42-pr-summary -->}"
PUBLIC_BASE_URL="${INPUT_PUBLIC_BASE_URL:-$SERVER_URL}"
PR_SUMMARY_PATH="${INPUT_PR_SUMMARY_PATH:-}"
# Trim: composite/workflow inputs can carry stray whitespace/newlines and break auth.
GITHUB_TOKEN_INPUT="${INPUT_GITHUB_TOKEN:-}"
GITHUB_TOKEN_INPUT="${GITHUB_TOKEN_INPUT#"${GITHUB_TOKEN_INPUT%%[![:space:]]*}"}"
GITHUB_TOKEN_INPUT="${GITHUB_TOKEN_INPUT%"${GITHUB_TOKEN_INPUT##*[![:space:]]}"}"
UPDATE_GITHUB_STATUS="${INPUT_UPDATE_GITHUB_STATUS:-false}"
GITHUB_STATUS_CONTEXT="${INPUT_GITHUB_STATUS_CONTEXT:-spec42/server}"
GITHUB_STATUS_STATE=""
PR_SUMMARY_API_URL=""
PR_COMMENT_URL=""
PR_COMMENT_ACTION=""

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

PYTHON_BIN="${PYTHON_BIN:-}"
if [[ -z "$PYTHON_BIN" ]]; then
  if command -v python3 >/dev/null 2>&1; then
    PYTHON_BIN="python3"
  elif command -v python >/dev/null 2>&1; then
    PYTHON_BIN="python"
  else
    echo "python3 or python is required" >&2
    exit 1
  fi
fi

if [[ "$GENERATE_PR_SUMMARY" == "true" ]]; then
  if [[ "$WAIT_FOR_COMPLETION" != "true" ]]; then
    echo "generate_pr_summary=true requires wait_for_completion=true" >&2
    exit 1
  fi
fi

if [[ "$POST_PR_COMMENT" == "true" ]]; then
  if [[ "$GENERATE_PR_SUMMARY" != "true" ]]; then
    echo "post_pr_comment=true requires generate_pr_summary=true" >&2
    exit 1
  fi
  if [[ -z "$GITHUB_TOKEN_INPUT" ]]; then
    echo "post_pr_comment=true requires github_token" >&2
    exit 1
  fi
  if [[ -z "${GITHUB_REPOSITORY:-}" || -z "${GITHUB_API_URL:-}" ]]; then
    echo "missing GitHub context (GITHUB_REPOSITORY/GITHUB_API_URL) for PR comment" >&2
    exit 1
  fi
fi

if [[ "$GENERATE_PR_SUMMARY" == "true" && -z "$BASE_RUN_ID" && -z "$BASE_BRANCH" ]]; then
  BASE_BRANCH="$("$PYTHON_BIN" - <<'PY'
import json
import os

event_path = os.environ.get("GITHUB_EVENT_PATH")
base_ref = ""
if event_path and os.path.exists(event_path):
    with open(event_path, "r", encoding="utf-8") as f:
        payload = json.load(f)
    base_ref = payload.get("pull_request", {}).get("base", {}).get("ref") or ""
print(base_ref)
PY
)"
  if [[ -z "$BASE_BRANCH" ]]; then
    echo "generate_pr_summary=true without base_run_id requires base_branch or pull_request.base.ref" >&2
    exit 1
  fi
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
ZIP_PATH="$WORK_DIR/workspace.zip"
MANIFEST_PATH="$WORK_DIR/manifest.json"
RESPONSE_PATH="$WORK_DIR/submit-response.json"
RUN_RESPONSE_PATH="$WORK_DIR/run-response.json"
BASE_RUN_RESPONSE_PATH="$WORK_DIR/base-run-response.json"
HEAD_RUN_RESPONSE_PATH="$WORK_DIR/head-run-response.json"
PR_COMMENT_BODY_PATH="$WORK_DIR/pr-comment-body.md"
PR_COMMENT_PAYLOAD_PATH="$WORK_DIR/pr-comment-payload.json"
PR_COMMENT_RESPONSE_PATH="$WORK_DIR/pr-comment-response.json"
PR_COMMENTS_RESPONSE_PATH="$WORK_DIR/pr-comments-response.json"
GITHUB_USER_RESPONSE_PATH="$WORK_DIR/github-user-response.json"

"$PYTHON_BIN" - <<'PY' "$ANALYSIS_ROOT" "$ZIP_PATH"
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

"$PYTHON_BIN" - <<'PY' "$MANIFEST_PATH"
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

RUN_ID="$("$PYTHON_BIN" - <<'PY' "$RESPONSE_PATH"
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

post_github_status() {
  local state="$1"
  local description="$2"
  if [[ "$UPDATE_GITHUB_STATUS" != "true" ]]; then
    return 0
  fi
  if [[ -z "$GITHUB_TOKEN_INPUT" ]]; then
    echo "update_github_status=true requires github_token" >&2
    exit 1
  fi
  if [[ -z "${GITHUB_REPOSITORY:-}" || -z "${GITHUB_SHA:-}" || -z "${GITHUB_API_URL:-}" ]]; then
    echo "missing GitHub context (GITHUB_REPOSITORY/GITHUB_SHA/GITHUB_API_URL) for status update" >&2
    exit 1
  fi

  local status_api="${GITHUB_API_URL%/}/repos/${GITHUB_REPOSITORY}/statuses/${GITHUB_SHA}"
  local payload_path="$WORK_DIR/github-status-${state}.json"
  "$PYTHON_BIN" - <<'PY' "$payload_path" "$state" "$description" "$RUN_API_URL" "$GITHUB_STATUS_CONTEXT"
import json
import sys
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(
        {
            "state": sys.argv[2],
            "description": sys.argv[3],
            "target_url": sys.argv[4],
            "context": sys.argv[5],
        },
        f,
    )
PY

  if ! curl --fail-with-body --silent --show-error \
    -X POST "$status_api" \
    -H "Authorization: token $GITHUB_TOKEN_INPUT" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    --data-binary "@${payload_path}" \
    > /dev/null; then
    echo "warning: unable to publish GitHub status '$state'; continuing Spec42 analysis" >&2
    return 0
  fi
  GITHUB_STATUS_STATE="$state"
}

post_github_status "pending" "Spec42 analysis in progress"

if [[ "$WAIT_FOR_COMPLETION" == "true" ]]; then
  START_TS="$(date +%s)"
  while true; do
    curl --fail-with-body --silent --show-error \
      -H "Authorization: Bearer $TOKEN" \
      "$RUN_API_URL" \
      > "$RUN_RESPONSE_PATH"

    RUN_STATUS="$("$PYTHON_BIN" - <<'PY' "$RUN_RESPONSE_PATH"
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
      post_github_status "success" "Spec42 analysis succeeded"
      break
    fi
    if [[ "$RUN_STATUS" == "failed" ]]; then
      echo "Spec42 run failed: $RUN_ID" >&2
      post_github_status "failure" "Spec42 analysis failed"
      "$PYTHON_BIN" - <<'PY' "$RUN_RESPONSE_PATH"
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
      post_github_status "error" "Spec42 analysis timed out"
      exit 1
    fi

    sleep "$POLL_SECONDS"
  done
fi

if [[ "$GENERATE_PR_SUMMARY" == "true" ]]; then
  if [[ "$RUN_STATUS" != "succeeded" ]]; then
    echo "Cannot generate PR summary because Spec42 run status is $RUN_STATUS" >&2
    exit 1
  fi

  if [[ -z "$BASE_RUN_ID" ]]; then
    curl --fail-with-body --silent --show-error \
      -H "Authorization: Bearer $TOKEN" \
      "$RUN_API_URL" \
      > "$HEAD_RUN_RESPONSE_PATH"
    HEAD_PROJECT_ID="$("$PYTHON_BIN" - <<'PY' "$HEAD_RUN_RESPONSE_PATH"
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)
value = data.get("project_id")
if isinstance(value, dict):
    value = value.get("id") or value.get("0")
if not value:
    raise SystemExit("head run response is missing project_id")
print(value)
PY
)"
    HEAD_REPOSITORY="$("$PYTHON_BIN" - <<'PY' "$HEAD_RUN_RESPONSE_PATH"
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)
print(data.get("repository_full_name") or data.get("repository_url") or "")
PY
)"
    if [[ -z "$HEAD_REPOSITORY" ]]; then
      echo "Cannot resolve base run because the head run has no repository metadata" >&2
      exit 1
    fi

    HEAD_PROJECT_ID_ENCODED="$("$PYTHON_BIN" -c 'from urllib.parse import quote; import sys; print(quote(sys.argv[1], safe=""))' "$HEAD_PROJECT_ID")"
    HEAD_REPOSITORY_ENCODED="$("$PYTHON_BIN" -c 'from urllib.parse import quote; import sys; print(quote(sys.argv[1], safe=""))' "$HEAD_REPOSITORY")"
    BASE_BRANCH_ENCODED="$("$PYTHON_BIN" -c 'from urllib.parse import quote; import sys; print(quote(sys.argv[1], safe=""))' "$BASE_BRANCH")"
    RUN_ID_ENCODED="$("$PYTHON_BIN" -c 'from urllib.parse import quote; import sys; print(quote(sys.argv[1], safe=""))' "$RUN_ID")"
    LATEST_RUN_API_URL="$SERVER_URL/v1/projects/$HEAD_PROJECT_ID_ENCODED/runs/latest?repository=$HEAD_REPOSITORY_ENCODED&branch=$BASE_BRANCH_ENCODED&status=succeeded&exclude_run_id=$RUN_ID_ENCODED"
    if ! curl --fail-with-body --silent --show-error \
      -H "Authorization: Bearer $TOKEN" \
      "$LATEST_RUN_API_URL" \
      > "$BASE_RUN_RESPONSE_PATH"; then
      echo "Unable to resolve a successful Spec42 base run for $HEAD_REPOSITORY on branch $BASE_BRANCH" >&2
      if [[ -s "$BASE_RUN_RESPONSE_PATH" ]]; then
        cat "$BASE_RUN_RESPONSE_PATH" >&2
      fi
      exit 1
    fi
    BASE_RUN_ID="$("$PYTHON_BIN" - <<'PY' "$BASE_RUN_RESPONSE_PATH"
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)
run_id = data.get("id")
if not run_id:
    raise SystemExit("latest run response is missing id")
print(run_id)
PY
)"
    echo "Resolved Spec42 base run: $BASE_RUN_ID"
  fi

  if [[ -z "$PR_SUMMARY_PATH" ]]; then
    PR_SUMMARY_PATH="${RUNNER_TEMP:-$PWD}/spec42-pr-summary-${RUN_ID}.md"
  fi
  mkdir -p "$(dirname "$PR_SUMMARY_PATH")"

  PUBLIC_BASE_URL_ENCODED="$("$PYTHON_BIN" -c 'from urllib.parse import quote; import sys; print(quote(sys.argv[1], safe=""))' "$PUBLIC_BASE_URL")"
  PR_SUMMARY_API_URL="$SERVER_URL/v1/runs/$BASE_RUN_ID/pr-summary/$RUN_ID?public_base_url=$PUBLIC_BASE_URL_ENCODED"
  curl --fail-with-body --silent --show-error \
    -H "Authorization: Bearer $TOKEN" \
    "$PR_SUMMARY_API_URL" \
    > "$PR_SUMMARY_PATH"
  echo "Wrote Spec42 PR summary: $PR_SUMMARY_PATH"
fi

if [[ "$POST_PR_COMMENT" == "true" ]]; then
  PR_NUMBER="$("$PYTHON_BIN" - <<'PY'
import json
import os

event_path = os.environ.get("GITHUB_EVENT_PATH")
number = ""
if event_path and os.path.exists(event_path):
    with open(event_path, "r", encoding="utf-8") as f:
        payload = json.load(f)
    number = payload.get("pull_request", {}).get("number") or ""
print(number)
PY
)"
  if [[ -z "$PR_NUMBER" ]]; then
    echo "post_pr_comment=true requires a pull_request event payload" >&2
    exit 1
  fi

  curl --fail-with-body --silent --show-error \
    -H "Authorization: token $GITHUB_TOKEN_INPUT" \
    -H "Accept: application/vnd.github+json" \
    "${GITHUB_API_URL%/}/user" \
    > "$GITHUB_USER_RESPONSE_PATH"
  GITHUB_VIEWER_LOGIN="$("$PYTHON_BIN" - <<'PY' "$GITHUB_USER_RESPONSE_PATH"
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)
login = data.get("login")
if not login:
    raise SystemExit("GitHub /user response is missing login")
print(login)
PY
)"

  "$PYTHON_BIN" - <<'PY' "$PR_SUMMARY_PATH" "$PR_COMMENT_BODY_PATH" "$PR_COMMENT_MARKER"
import sys
from pathlib import Path

source = Path(sys.argv[1])
target = Path(sys.argv[2])
marker = sys.argv[3]
body = source.read_text(encoding="utf-8")
if marker and marker not in body:
    body = f"{marker}\n{body}"
target.write_text(body, encoding="utf-8")
PY
  "$PYTHON_BIN" - <<'PY' "$PR_COMMENT_BODY_PATH" "$PR_COMMENT_PAYLOAD_PATH"
import json
import sys
from pathlib import Path

body = Path(sys.argv[1]).read_text(encoding="utf-8")
with open(sys.argv[2], "w", encoding="utf-8") as f:
    json.dump({"body": body}, f)
PY

  COMMENTS_API_URL="${GITHUB_API_URL%/}/repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments?per_page=100"
  curl --fail-with-body --silent --show-error \
    -H "Authorization: token $GITHUB_TOKEN_INPUT" \
    -H "Accept: application/vnd.github+json" \
    "$COMMENTS_API_URL" \
    > "$PR_COMMENTS_RESPONSE_PATH"
  EXISTING_COMMENT_ID="$("$PYTHON_BIN" - <<'PY' "$PR_COMMENTS_RESPONSE_PATH" "$GITHUB_VIEWER_LOGIN" "$PR_COMMENT_MARKER"
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    comments = json.load(f)
viewer = sys.argv[2]
marker = sys.argv[3]
for comment in comments:
    if comment.get("user", {}).get("login") == viewer and marker in (comment.get("body") or ""):
        print(comment.get("id"))
        break
PY
)"

  if [[ -n "$EXISTING_COMMENT_ID" ]]; then
    curl --fail-with-body --silent --show-error \
      -X PATCH "${GITHUB_API_URL%/}/repos/${GITHUB_REPOSITORY}/issues/comments/${EXISTING_COMMENT_ID}" \
      -H "Authorization: token $GITHUB_TOKEN_INPUT" \
      -H "Accept: application/vnd.github+json" \
      -H "Content-Type: application/json" \
      --data-binary "@${PR_COMMENT_PAYLOAD_PATH}" \
      > "$PR_COMMENT_RESPONSE_PATH"
    PR_COMMENT_ACTION="updated"
  else
    curl --fail-with-body --silent --show-error \
      -X POST "${GITHUB_API_URL%/}/repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments" \
      -H "Authorization: token $GITHUB_TOKEN_INPUT" \
      -H "Accept: application/vnd.github+json" \
      -H "Content-Type: application/json" \
      --data-binary "@${PR_COMMENT_PAYLOAD_PATH}" \
      > "$PR_COMMENT_RESPONSE_PATH"
    PR_COMMENT_ACTION="created"
  fi
  PR_COMMENT_URL="$("$PYTHON_BIN" - <<'PY' "$PR_COMMENT_RESPONSE_PATH"
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)
print(data.get("html_url") or "")
PY
)"
  echo "Spec42 PR comment $PR_COMMENT_ACTION: $PR_COMMENT_URL"
fi

{
  echo "run_id=$RUN_ID"
  echo "run_status=$RUN_STATUS"
  echo "run_api_url=$RUN_API_URL"
  echo "pr_summary_path=$PR_SUMMARY_PATH"
  echo "pr_summary_api_url=$PR_SUMMARY_API_URL"
  echo "base_run_id=$BASE_RUN_ID"
  echo "pr_comment_url=$PR_COMMENT_URL"
  echo "pr_comment_action=$PR_COMMENT_ACTION"
  echo "github_status_state=$GITHUB_STATUS_STATE"
} >> "$GITHUB_OUTPUT"
