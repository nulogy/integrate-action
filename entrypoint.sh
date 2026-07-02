#!/bin/bash

set -e

echo "Integrate Action v2.0.0"

# Workaround until new Actions support neutral strategy
# See how it was before: https://developer.github.com/actions/creating-github-actions/accessing-the-runtime-environment/#exit-codes-and-statuses
NEUTRAL_EXIT_CODE=0

# since https://github.blog/2022-04-12-git-security-vulnerability-announced/
git config --global --add safe.directory /github/workspace

# shellcheck source=ci_checks.sh
source /ci_checks.sh

# Skip if not a PR
echo "Checking if issue is a pull request..."
(jq -r ".issue.pull_request.url" "$GITHUB_EVENT_PATH") || exit $NEUTRAL_EXIT_CODE

if [[ "$(jq -r ".action" "$GITHUB_EVENT_PATH")" != "created" ]]; then
  echo "This is not a new comment event!"
  exit $NEUTRAL_EXIT_CODE
fi

COMMENT_BODY=$(jq -r ".comment.body" "$GITHUB_EVENT_PATH")
if [[ "$COMMENT_BODY" == *"/hotfix"* ]]; then
  ACTION_MODE="hotfix"
elif [[ "$COMMENT_BODY" == *"/integrate"* ]]; then
  ACTION_MODE="integrate"
else
  echo "Comment does not contain /integrate or /hotfix. Skipping."
  exit $NEUTRAL_EXIT_CODE
fi
echo "Action mode: $ACTION_MODE"

PR_NUMBER=$(jq -r ".issue.number" "$GITHUB_EVENT_PATH")
echo "Collecting information about PR #$PR_NUMBER of $GITHUB_REPOSITORY..."

if [[ -z "$GITHUB_TOKEN" ]]; then
  echo "Set the GITHUB_TOKEN env variable."
  exit 1
fi

URI=https://api.github.com
API_HEADER="Accept: application/vnd.github.v3+json"
AUTH_HEADER="Authorization: token $GITHUB_TOKEN"

# CI-wait configuration (all optional; defaults preserve prior behavior).
# Max seconds to wait for CI before giving up (fail-closed). Must exceed the
# slowest check (spark's SFac e2e has run ~2.6h) yet stay under this job's own
# timeout (GitHub's default is 6h).
CI_WAIT_TIMEOUT_SECONDS="${CI_WAIT_TIMEOUT_SECONDS:-14400}"
# Comma-separated check-run names that MUST be present and pass before merging.
# When empty, the action instead gates on every check-run present on the commit
# (it cannot otherwise tell which checks are expected).
REQUIRED_CHECK_RUNS="${REQUIRED_CHECK_RUNS:-}"
# Comma-separated path prefixes. When set, REQUIRED_CHECK_RUNS is enforced only
# if the PR changes a file under one of these prefixes, so a PR that doesn't
# touch the relevant product isn't blocked waiting for checks that never run.
# When empty but REQUIRED_CHECK_RUNS is set, the required checks always apply.
REQUIRED_CHECK_RUNS_PATHS="${REQUIRED_CHECK_RUNS_PATHS:-}"

USER_URL=$(jq -r ".comment.user.url" "$GITHUB_EVENT_PATH")
user_resp=$(curl -X GET -s -H "${API_HEADER}" -H "${AUTH_HEADER}" "${USER_URL}")

USER_FULL_NAME=$(echo "$user_resp" | jq -r ".name")

# add a Thumbs Up reaction to the comment
COMMENTS_URL=$(jq -r ".comment.url" "$GITHUB_EVENT_PATH")
PREVIEW_API_HEADER="Accept: application/vnd.github.squirrel-girl-preview+json"
curl -X POST -s -H "${AUTH_HEADER}" -H "${PREVIEW_API_HEADER}" -d '{ "content": "+1" }' "$COMMENTS_URL/reactions"

if [[ "$USER_FULL_NAME" == "null" ]]; then
  echo "USER_RESPONSE: $user_resp"
  echo "You must have your full name set up on your GitHub user profile so that the integration can be attributed to you!"
  exit 1
fi

PR_URL="${URI}/repos/$GITHUB_REPOSITORY/pulls/$PR_NUMBER"

pr_resp=$(curl -X GET -s -H "${AUTH_HEADER}" -H "${API_HEADER}" "${PR_URL}")

BASE_REPO=$(echo "$pr_resp" | jq -r .base.repo.full_name)
BASE_BRANCH=$(echo "$pr_resp" | jq -r .base.ref)
PR_TITLE=$(echo "$pr_resp" | jq -r .title)

if [[ -z "$BASE_BRANCH" ]]; then
  echo "Cannot get base branch information for PR #$PR_NUMBER!"
  echo "API response: $pr_resp"
  exit 1
fi

HEAD_REPO=$(echo "$pr_resp" | jq -r .head.repo.full_name)
HEAD_BRANCH=$(echo "$pr_resp" | jq -r .head.ref)

echo "Base branch for PR #$PR_NUMBER is $BASE_BRANCH"

if [[ "$BASE_REPO" != "$HEAD_REPO" ]]; then
  echo "PRs from forks are not supported at the moment."
  exit 1
fi

git remote set-url origin https://x-access-token:$GITHUB_TOKEN@github.com/$GITHUB_REPOSITORY.git
git config --global user.email "action@github.com"
git config --global user.name "GitHub Action"

# Make sure branches are up-to-date
git fetch origin $BASE_BRANCH
git fetch origin $HEAD_BRANCH

# Rebase
git checkout -b $HEAD_BRANCH origin/$HEAD_BRANCH
git rebase origin/$BASE_BRANCH
git push --force-with-lease
HEAD_BRANCH_HEAD=$(git rev-parse HEAD)
echo "(Potentially) Rebased commit hash of HEAD is: $HEAD_BRANCH_HEAD"

# Does the PR touch any of the given comma-separated path prefixes? Paginates the
# PR file list. Returns 0 (in scope) on a match OR if the file list can't be
# fetched (fail-closed: an undeterminable scope must not silently weaken the
# gate); returns 1 only when the full file list is known and matches nothing.
pr_touches_paths() {
  local prefixes_csv="$1" page=1 resp count files
  while : ; do
    resp=""
    for _ in 1 2 3; do
      resp=$(curl -s --max-time 30 -H "${AUTH_HEADER}" -H "${API_HEADER}" "${PR_URL}/files?per_page=100&page=$page") || resp=""
      if [[ -n "$resp" ]] && jq -e 'type == "array"' <<<"$resp" >/dev/null 2>&1; then
        break
      fi
      resp=""
      sleep 3
    done
    if [[ -z "$resp" ]]; then
      echo "Could not fetch changed files after retries; enforcing required checks (fail-closed)." >&2
      return 0
    fi
    count=$(jq 'length' <<<"$resp")
    if [[ "$count" -eq 0 ]]; then
      return 1
    fi
    files=$(jq -r '.[].filename' <<<"$resp")
    if any_path_has_prefix "$files" "$prefixes_csv"; then
      return 0
    fi
    if [[ "$count" -lt 100 ]]; then
      return 1
    fi
    page=$((page + 1))
  done
}

# Enforce REQUIRED_CHECK_RUNS on this PR only when in scope (see config above).
required_active="false"
if [[ -n "$REQUIRED_CHECK_RUNS" ]]; then
  if [[ -z "$REQUIRED_CHECK_RUNS_PATHS" ]] || pr_touches_paths "$REQUIRED_CHECK_RUNS_PATHS"; then
    required_active="true"
  fi
fi
if [[ "$required_active" == "true" ]]; then
  echo "Required check-runs enforced for this PR: $REQUIRED_CHECK_RUNS"
else
  echo "No required check-runs in scope; gating on every check-run present on the commit."
fi

# Wait for BOTH CI systems to report on the rebased commit ($HEAD_BRANCH_HEAD):
#   - PackManager CI (Buildkite) -> legacy commit status (/status)
#   - SFac CI (GitHub Actions)   -> check-runs (/check-runs), invisible to /status
# No pre-loop settle is needed: Buildkite posts a pending status within seconds
# of the force-push and holds it for minutes (until its build finishes), so this
# loop keeps waiting long after the Actions check-runs have registered.
deadline=$(( $(date +%s) + CI_WAIT_TIMEOUT_SECONDS ))
while true; do
  sleep 10

  if (( $(date +%s) > deadline )); then
    echo "Timed out after ${CI_WAIT_TIMEOUT_SECONDS}s waiting for CI on $HEAD_BRANCH @ $HEAD_BRANCH_HEAD. Cancelling integration."
    exit 1
  fi

  status_json=$(curl -s --max-time 30 -H "${AUTH_HEADER}" -H "${API_HEADER}" "${URI}/repos/$GITHUB_REPOSITORY/commits/$HEAD_BRANCH_HEAD/status") || {
    echo "Polling for CI: status fetch failed (transient), retrying..."
    continue
  }
  # An error/rate-limit body, or a non-JSON edge response, must not abort the
  # run: fall back to "null" so the case below simply keeps polling.
  STATUS_STATE=$(jq -r '.state // "null"' <<<"$status_json" 2>/dev/null || echo "null")
  case "$STATUS_STATE" in
    success) ;;                                     # legacy CI passed; check the check-runs next
    failure|error)
      echo "CI did not pass (legacy status = $STATUS_STATE) for $HEAD_BRANCH @ $HEAD_BRANCH_HEAD. Cancelling integration."
      exit 1 ;;
    *)                                              # "pending", or "null" from a transient error body
      echo "Polling for CI: legacy statuses not final yet ($STATUS_STATE)..."
      continue ;;
  esac

  check_runs_json=$(curl -s --max-time 30 -H "${AUTH_HEADER}" -H "${API_HEADER}" "${URI}/repos/$GITHUB_REPOSITORY/commits/$HEAD_BRANCH_HEAD/check-runs") || {
    echo "Polling for CI: check-runs fetch failed (transient), retrying..."
    continue
  }
  if ! check_runs_payload_valid "$check_runs_json"; then
    echo "Polling for CI: check-runs endpoint returned no usable payload, retrying..."
    continue
  fi

  if [[ "$required_active" == "true" ]]; then
    pending=$(required_checks_pending "$check_runs_json" "$REQUIRED_CHECK_RUNS")
    if [[ -n "$pending" ]]; then
      echo "Polling for CI: waiting on required check-run(s): $(echo "$pending" | tr '\n' ' ')"
      continue
    fi
  else
    incomplete=$(check_runs_incomplete_count "$check_runs_json")
    if [[ "$incomplete" -gt 0 ]]; then
      echo "Polling for CI: $incomplete check-run(s) still running..."
      continue
    fi
  fi

  break
done

# Reaching here means the legacy status is "success"; fail on any check-run problem.
if [[ "$required_active" == "true" ]]; then
  required_failures=$(required_checks_failures "$check_runs_json" "$REQUIRED_CHECK_RUNS")
  if [[ -n "$required_failures" ]]; then
    echo "CI did not pass. Required check-run problem(s) for $HEAD_BRANCH @ $HEAD_BRANCH_HEAD:"
    echo "$required_failures"
    exit 1
  fi
else
  failed_runs=$(check_runs_failures "$check_runs_json")
  if [[ -n "$failed_runs" ]]; then
    echo "CI did not pass. Failing check-runs for $HEAD_BRANCH @ $HEAD_BRANCH_HEAD:"
    echo "$failed_runs"
    exit 1
  fi
fi

# Hit the merge button. Pass sha=$HEAD_BRANCH_HEAD so GitHub only merges if the
# branch head still matches the exact commit CI validated (a race push aborts).
MERGE_COMMIT_TITLE="Merge branch '$HEAD_BRANCH' on behalf of $USER_FULL_NAME"
if [[ "$ACTION_MODE" == "hotfix" ]]; then
  MERGE_COMMIT_TITLE="$MERGE_COMMIT_TITLE [skip tests]"
fi

if [[ $ADD_CHANGE_LOGS = "true" ]]; then
  COMMENT_TOKEN="(?i)change\\\\s?log:?"

  PR_COMMENTS_URL="$URI/repos/$GITHUB_REPOSITORY/issues/$PR_NUMBER/comments"
  GITHUB_PR_COMMENTS=$(curl -X GET -s -H "${API_HEADER}" -H "${AUTH_HEADER}" "${PR_COMMENTS_URL}")

  MESSAGE=$(echo $GITHUB_PR_COMMENTS | jq ".[].body | select(test(\"$COMMENT_TOKEN\")) | sub(\"$COMMENT_TOKEN\"; \"\")" | tr -d '"')
  TRIMMED_MESSAGE=$(echo "$MESSAGE" | sed 's/^[[:space:]]*//')
  NEWLINE_MESSAGE=$( sed 's/\\r\\n/\'$'\n''/g' <<< "$TRIMMED_MESSAGE" | sed 's/^/  /' )

  MERGE_COMMIT_MESSAGE="\
  $PR_TITLE

  Change Log
  https://github.com/$GITHUB_REPOSITORY/pulls/$PR_NUMBER
  ${NEWLINE_MESSAGE}"

  JSON_STRING=$( jq -n \
                --arg title "$MERGE_COMMIT_TITLE" \
                --arg message "$MERGE_COMMIT_MESSAGE" \
                --arg sha "$HEAD_BRANCH_HEAD" \
                '{commit_title: $title, commit_message: $message, sha: $sha}' )

  merge_resp=$(curl -X PUT -s -H "${AUTH_HEADER}" -H "${API_HEADER}" -d "$JSON_STRING" "${PR_URL}/merge")
else
  JSON_STRING=$( jq -n \
                --arg title "$MERGE_COMMIT_TITLE" \
                --arg sha "$HEAD_BRANCH_HEAD" \
                '{commit_title: $title, sha: $sha}' )

  merge_resp=$(curl -X PUT -s -H "${AUTH_HEADER}" -H "${API_HEADER}" -d "$JSON_STRING" "${PR_URL}/merge")
fi

if [[ $merge_resp != *"Pull Request successfully merged"* ]]; then
  echo "Could not merge PR. Error from GitHub: '$merge_resp'"
  exit 1
fi
