#!/usr/bin/env bash
# Pure helpers for evaluating CI state on a commit. No network and no globals:
# every input is an argument, so these are unit-testable with fixtures.
#
# The "$1" argument is a GET /commits/{sha}/check-runs REST payload:
#   {"total_count":N,"check_runs":[{name,status,conclusion,started_at,id},...]}
# GitHub can list SEVERAL runs for the same name (reruns, concurrency-cancelled
# then re-created). Every helper evaluates only the LATEST run per name so a
# superseded run never masks or fails the current one. "Latest" = highest
# check-run id (monotonic at creation), then started_at as a tiebreak.

# Check-run conclusions we treat as passing. Anything else on a completed run
# (failure, timed_out, cancelled, action_required, stale, or null/unknown)
# blocks the merge.
CI_OK_CONCLUSIONS='["success","neutral","skipped"]'

# jq prelude defining `latest_per_name`: check_runs reduced to the newest run per
# name, with unnamed runs dropped (a null name cannot be an object key).
_ci_jq_latest='def latest_per_name:
  [ (.check_runs // []) | map(select(.name != null)) | group_by(.name)[]
    | max_by([(.id // 0), (.started_at // "")]) ];'

# True if $1 is a well-formed check-runs payload (has a .check_runs array), so
# callers can distinguish it from a transient API error body ({"message":...})
# and keep polling instead of aborting.
check_runs_payload_valid() {
  jq -e '(.check_runs | type) == "array"' <<<"$1" >/dev/null 2>&1
}

# Count latest-per-name check-runs that have not finished yet.
check_runs_incomplete_count() {
  jq -r "$_ci_jq_latest"'
    latest_per_name | map(select(.status != "completed")) | length
  ' <<<"$1"
}

# "name: conclusion" for each latest-per-name completed check-run whose
# conclusion is not acceptable. Empty output = all completed runs passed.
check_runs_failures() {
  jq -r --argjson ok "$CI_OK_CONCLUSIONS" "$_ci_jq_latest"'
    latest_per_name[]
    | select(.status == "completed")
    | select(.conclusion as $c | ($ok | index($c)) | not)
    | "\(.name): \(.conclusion // "none")"
  ' <<<"$1"
}

# Of the comma-separated required names in $2 (surrounding whitespace trimmed),
# print those NOT yet present-and-completed (absent from the commit, or latest
# run still running). Empty output = every required check has a completed latest
# run. Used to keep waiting until the expected checks actually show up.
required_checks_pending() {
  jq -r --arg req "$2" "$_ci_jq_latest"'
    (latest_per_name | map({ (.name): . }) | add // {}) as $byname
    | ($req | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0)))[]
    | select( ($byname[.] // null) == null or $byname[.].status != "completed" )
  ' <<<"$1"
}

# Of the comma-separated required names in $2 (surrounding whitespace trimmed),
# print "name: reason" for each that is absent ("missing") or whose latest
# completed conclusion is not acceptable. Empty output = every required check is
# present and passed.
required_checks_failures() {
  jq -r --arg req "$2" --argjson ok "$CI_OK_CONCLUSIONS" "$_ci_jq_latest"'
    (latest_per_name | map({ (.name): . }) | add // {}) as $byname
    | ($req | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0)))[]
    | . as $name
    | ($byname[$name] // null) as $run
    | if $run == null then "\($name): missing"
      elif ($ok | index($run.conclusion)) then empty
      else "\($name): \($run.conclusion // "incomplete")"
      end
  ' <<<"$1"
}

# True if any newline-separated path in $1 starts with any comma-separated
# prefix in $2. Matching is literal prefix (not glob), so "SensrTrxMES/" matches
# "SensrTrxMES/x" but not "SensrTrxMESX/x".
any_path_has_prefix() {
  local paths="$1" prefixes_csv="$2" prefix p
  while IFS= read -r prefix; do
    [[ -z "$prefix" ]] && continue
    while IFS= read -r p; do
      [[ -n "$p" && "$p" == "$prefix"* ]] && return 0
    done <<<"$paths"
  done < <(echo "$prefixes_csv" | tr ',' '\n')
  return 1
}
