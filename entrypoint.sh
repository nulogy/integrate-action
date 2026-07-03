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

# CI-wait configuration (all optional). NOTE: v2 gates differently from v1 (see
# the README); leaving these unset does NOT reproduce v1's legacy-status-only gate.

# Seconds to wait for CI PER rebase attempt before giving up (fail-closed). The
# action retries across rebases (see MAX_REBASE_ATTEMPTS), so total runtime is
# bounded by the enclosing job's own timeout -- raise the job's timeout-minutes
# for long "set and forget" runs.
CI_WAIT_TIMEOUT_SECONDS="${CI_WAIT_TIMEOUT_SECONDS:-7200}"
# How many times to rebase onto the latest base and re-run CI when the base keeps
# advancing during CI. High by default so /integrate is "set and forget"; the
# enclosing job's own timeout is the ultimate backstop.
MAX_REBASE_ATTEMPTS="${MAX_REBASE_ATTEMPTS:-100}"
# JSON array of rules pairing path prefixes with required check names, e.g.
#   [ {"checks":["buildkite/packmanager"]},
#     {"paths":["some/dir/"],"checks":["test","e2e"]} ]
# A rule with no "paths" is always required; with "paths" it applies only when the
# PR changes a file under one of those prefixes. A required check must be PRESENT
# (and pass) before merging. Names match both GitHub Actions check-runs and legacy
# commit-status contexts (e.g. "buildkite/packmanager"). When empty, the action
# gates only on whatever checks are present on the commit.
REQUIRED_CHECKS="${REQUIRED_CHECKS:-}"

# Reject non-positive-integer numeric config up front (e.g. "4h", "0600", "") so
# it fails clearly instead of yielding a misleading timeout or a wrong bound.
for _var in CI_WAIT_TIMEOUT_SECONDS MAX_REBASE_ATTEMPTS; do
  if ! [[ "${!_var}" =~ ^[1-9][0-9]*$ ]]; then
    echo "$_var must be a positive integer, got '${!_var}'. Cancelling integration."
    exit 1
  fi
done

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

# Check out the PR branch. The base is (re)fetched and the branch (re)rebased
# per attempt inside the merge loop below.
git fetch origin $HEAD_BRANCH
git checkout -b $HEAD_BRANCH origin/$HEAD_BRANCH

# Does the PR touch any of the given comma-separated path prefixes? Paginates the
# PR file list. Returns 0 on a match, 1 when the full file list is known and
# matches nothing. If the file list can't be fetched after retries it exits the
# whole action (fail-closed: an undeterminable scope must not silently weaken the
# gate, and failing fast beats blocking on a check that will never run).
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
      echo "Could not fetch the PR's changed files after retries; cannot determine required-check scope. Cancelling integration (re-run /integrate)."
      exit 1
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

# Build the set of required check names for this PR from REQUIRED_CHECKS (see
# config above). A rule with no "paths" always applies; otherwise it applies when
# the PR changes a file under one of its prefixes. Names may refer to check-runs
# or legacy status contexts.
required_names=""
if [[ -n "$REQUIRED_CHECKS" ]]; then
  if jq -e 'type == "array"' <<<"$REQUIRED_CHECKS" >/dev/null 2>&1; then
    rule_count=$(jq 'length' <<<"$REQUIRED_CHECKS")
    i=0
    # Extract each rule's fields by index (not via read+IFS: a tab delimiter is
    # IFS-whitespace, which would drop an empty "paths" field and misread the row).
    while [[ "$i" -lt "$rule_count" ]]; do
      # Type-guard so a malformed rule (e.g. checks as a string, or a non-object)
      # yields "" and is skipped, rather than erroring out and aborting under set -e.
      rule_paths=$(jq -r --argjson i "$i" '(.[$i]) as $r | if ($r | type) == "object" and (($r.paths | type) == "array") then ($r.paths | map(select(type == "string")) | join(",")) else "" end' <<<"$REQUIRED_CHECKS")
      rule_checks=$(jq -r --argjson i "$i" '(.[$i]) as $r | if ($r | type) == "object" and (($r.checks | type) == "array") then ($r.checks | map(select(type == "string")) | join(",")) else "" end' <<<"$REQUIRED_CHECKS")
      i=$((i + 1))
      if [[ -z "$rule_checks" ]]; then
        continue
      fi
      if [[ -z "$rule_paths" ]] || pr_touches_paths "$rule_paths"; then
        required_names="${required_names:+$required_names,}$rule_checks"
      fi
    done
  else
    echo "REQUIRED_CHECKS is set but is not a JSON array. Cancelling integration (fix the config)."
    exit 1
  fi
fi
if [[ -n "$required_names" ]]; then
  echo "Required checks for this PR: $required_names"
else
  echo "No required checks in scope; gating on every check present on the commit."
fi

# Poll the commit's checks via one GraphQL statusCheckRollup query, which returns
# legacy status contexts (e.g. Buildkite) AND GitHub Actions check-runs together,
# so both are gated uniformly.
OWNER="${GITHUB_REPOSITORY%%/*}"
REPO="${GITHUB_REPOSITORY##*/}"
# $owner/$name/$oid are GraphQL variables, not shell -- single quotes are correct.
# shellcheck disable=SC2016
GQL_QUERY='query($owner:String!,$name:String!,$oid:GitObjectID!){repository(owner:$owner,name:$name){object(oid:$oid){... on Commit{statusCheckRollup{contexts(first:100){totalCount nodes{__typename ... on CheckRun{name status conclusion startedAt databaseId checkSuite{app{databaseId}}} ... on StatusContext{context state createdAt}}}}}}}}'

# Outer loop: rebase onto the LATEST base, wait for CI, then re-check the base
# right before merging. If another PR merged during CI (base advanced), re-rebase
# and re-verify so we never merge a commit that was only CI'd against a stale
# base. The pre-merge re-check narrows -- but cannot fully close -- this window;
# the gap between that check and the merge call itself needs a merge queue.
rebase_attempt=0
while true; do  # OUTER: rebase / CI / re-check base / merge
  rebase_attempt=$((rebase_attempt + 1))
  if [[ "$rebase_attempt" -gt "$MAX_REBASE_ATTEMPTS" ]]; then
    echo "Base advanced through $MAX_REBASE_ATTEMPTS CI cycles; giving up. Re-run /integrate."
    exit 1
  fi

  git fetch origin $BASE_BRANCH
  base_sha=$(git rev-parse "origin/$BASE_BRANCH")
  if ! git rebase "origin/$BASE_BRANCH"; then
    git rebase --abort || true
    echo "Cannot rebase $HEAD_BRANCH onto updated $BASE_BRANCH (conflict). Cancelling integration."
    exit 1
  fi
  if ! git push --force-with-lease; then
    echo "Could not force-push rebased $HEAD_BRANCH (was it pushed to during CI?). Cancelling integration."
    exit 1
  fi
  HEAD_BRANCH_HEAD=$(git rev-parse HEAD)
  echo "Rebased HEAD is $HEAD_BRANCH_HEAD (attempt $rebase_attempt/$MAX_REBASE_ATTEMPTS onto base $base_sha)"

  # Fresh CI-wait budget for THIS rebase attempt, so a base advance late in one
  # attempt doesn't starve the next attempt's CI.
  deadline=$(( $(date +%s) + CI_WAIT_TIMEOUT_SECONDS ))
  while true; do
    sleep 10

  if (( $(date +%s) > deadline )); then
    echo "Timed out after ${CI_WAIT_TIMEOUT_SECONDS}s waiting for CI on $HEAD_BRANCH @ $HEAD_BRANCH_HEAD. Cancelling integration."
    exit 1
  fi

  gql_payload=$(jq -n --arg q "$GQL_QUERY" --arg owner "$OWNER" --arg name "$REPO" --arg oid "$HEAD_BRANCH_HEAD" \
    '{query: $q, variables: {owner: $owner, name: $name, oid: $oid}}')
  rollup_resp=$(curl -s --max-time 30 -H "${AUTH_HEADER}" -H "Content-Type: application/json" -d "$gql_payload" "${URI}/graphql") || {
    echo "Polling for CI: rollup fetch failed (transient), retrying..."
    continue
  }
  if ! rollup_payload_valid "$rollup_resp"; then
    echo "Polling for CI: rollup response not usable yet, retrying..."
    continue
  fi
  # Refuse to merge on a partial view: the rollup returns at most 100 contexts,
  # so if the commit has more, some checks are invisible to us.
  context_total=$(jq '.data.repository.object.statusCheckRollup.contexts.totalCount // 0' <<<"$rollup_resp")
  if [[ "$context_total" -gt 100 ]]; then
    echo "Commit $HEAD_BRANCH_HEAD has $context_total checks; only 100 are fetched. Refusing to merge on a partial view. Cancelling integration."
    exit 1
  fi
  check_runs_json=$(normalize_rollup "$rollup_resp")

  # Wait for the required checks to APPEAR and finish. This anchors the wait:
  # because sibling checks register together, a newly-added check will have
  # registered by the time an anchor has, so the "all present" wait below then
  # covers it without it being listed in REQUIRED_CHECKS.
  if [[ -n "$required_names" ]]; then
    pending=$(required_checks_pending "$check_runs_json" "$required_names")
    if [[ -n "$pending" ]]; then
      echo "Polling for CI: waiting on required check(s): $(echo "$pending" | tr '\n' ' ')"
      continue
    fi
  fi

  # Floor for the no-required-checks mode: never merge on an empty check set --
  # wait until at least one check has appeared so an unregistered CI run can't
  # look "green". (With REQUIRED_CHECKS set, the anchor above already does this.)
  if [[ -z "$required_names" ]]; then
    present_count=$(jq '.check_runs | length' <<<"$check_runs_json")
    if [[ "$present_count" -eq 0 ]]; then
      echo "Polling for CI: no checks have appeared on the commit yet, retrying..."
      continue
    fi
  fi

  # Wait for every check present on the commit to finish.
  incomplete=$(check_runs_incomplete_count "$check_runs_json")
  if [[ "$incomplete" -gt 0 ]]; then
    echo "Polling for CI: $incomplete check(s) still running..."
    continue
  fi

  break
done

# Every check present on the commit must have concluded acceptably...
failed_runs=$(check_runs_failures "$check_runs_json")
if [[ -n "$failed_runs" ]]; then
  echo "CI did not pass. Failing checks for $HEAD_BRANCH @ $HEAD_BRANCH_HEAD:"
  echo "$failed_runs"
  exit 1
fi

# ...and the required checks must additionally be PRESENT (not merely "not
# failing") -- this is what guarantees we didn't merge before they ran.
if [[ -n "$required_names" ]]; then
  required_failures=$(required_checks_failures "$check_runs_json" "$required_names")
  if [[ -n "$required_failures" ]]; then
    echo "CI did not pass. Required check problem(s) for $HEAD_BRANCH @ $HEAD_BRANCH_HEAD:"
    echo "$required_failures"
    exit 1
  fi
fi

# Assemble the merge payload (including fetching change-log comments) BEFORE the
# base re-check, so the only work left between the re-check and the merge call is
# the merge itself -- keeping the residual race window as small as possible.
# sha=$HEAD_BRANCH_HEAD makes GitHub merge only the exact commit CI validated.
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
else
  JSON_STRING=$( jq -n \
                --arg title "$MERGE_COMMIT_TITLE" \
                --arg sha "$HEAD_BRANCH_HEAD" \
                '{commit_title: $title, sha: $sha}' )
fi

# Re-check the base as late as possible: if it advanced during CI, another PR
# merged, so re-rebase and re-verify rather than merge a stale-CI'd commit. The
# only work after this is the merge PUT itself; the residual gap between here and
# that call needs a merge queue to fully close.
git fetch origin $BASE_BRANCH
if [[ "$(git rev-parse "origin/$BASE_BRANCH")" != "$base_sha" ]]; then
  echo "Base advanced during CI; re-rebasing and re-verifying before merge."
  continue
fi

merge_resp=$(curl -X PUT -s -H "${AUTH_HEADER}" -H "${API_HEADER}" -d "$JSON_STRING" "${PR_URL}/merge")

if [[ $merge_resp != *"Pull Request successfully merged"* ]]; then
  echo "Could not merge PR. Error from GitHub: '$merge_resp'"
  exit 1
fi

break  # OUTER: merged successfully
done
