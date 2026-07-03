#!/usr/bin/env bash
# Pure helpers for evaluating CI state on a commit. No network and no globals:
# every input is an argument, so these are unit-testable with fixtures.
#
# "$1" is a check-runs-shaped payload as produced by normalize_rollup:
#   {"check_runs":[{name,status,conclusion,started_at,id,source},...]}
# "source" distinguishes a check's origin (a check-run's app, or "status" for a
# legacy commit-status context). GitHub can list several runs for the same name
# (reruns), and two different sources can share a name; helpers evaluate the
# LATEST run per (name, source) -- newest id, then started_at -- so a rerun never
# masks the current run and two distinct same-named checks are never collapsed.

# Check-run conclusions we treat as passing. Anything else on a completed run
# (failure, timed_out, cancelled, action_required, stale, or null/unknown)
# blocks the merge. (skipped passes: a skipped check must not block a merge.)
CI_OK_CONCLUSIONS='["success","neutral","skipped"]'

# jq prelude defining `latest_per_name`: reduce .check_runs to the newest run per
# (name, source). Unnamed runs are dropped (a null name cannot be an object key).
_ci_jq_latest='def latest_per_name:
  [ (.check_runs // []) | map(select(.name != null)) | group_by([.name, .source])[]
    | max_by([(.id // 0), (.started_at // "")]) ];'

# True if $1 is a usable GraphQL statusCheckRollup response: no top-level errors
# and the commit object resolved. (A resolved commit with no checks yet has a
# null rollup, which is still usable -> normalizes to an empty set.)
rollup_payload_valid() {
  jq -e '(.errors | not) and (.data.repository.object != null)' <<<"$1" >/dev/null 2>&1
}

# Normalize a GraphQL statusCheckRollup response into the {check_runs:[...]} shape
# the helpers below consume, so legacy StatusContexts (e.g. Buildkite) and Actions
# CheckRuns are evaluated uniformly. StatusContext.state maps onto (status,
# conclusion): SUCCESS -> completed/success; FAILURE|ERROR -> completed/failure;
# PENDING|EXPECTED -> in_progress/none (i.e. not yet completed). CheckRun enums
# are lowercased. "source" keeps a status and a same-named check-run (or two
# same-named check-runs from different apps) distinct so neither is dropped.
normalize_rollup() {
  jq '{
    check_runs: [
      (.data.repository.object.statusCheckRollup.contexts.nodes // [])[]
      | if .__typename == "CheckRun" then
          { name: .name,
            status: ((.status // "") | ascii_downcase),
            conclusion: (if .conclusion == null then null else (.conclusion | ascii_downcase) end),
            started_at: .startedAt,
            id: (.databaseId // 0),
            source: ("check:" + ((.checkSuite.app.databaseId // 0) | tostring)) }
        else
          { name: .context,
            status: (if (.state == "SUCCESS" or .state == "FAILURE" or .state == "ERROR") then "completed" else "in_progress" end),
            conclusion: (if .state == "SUCCESS" then "success" elif (.state == "FAILURE" or .state == "ERROR") then "failure" else null end),
            started_at: .createdAt,
            id: 0,
            source: "status" }
        end
    ]
  }' <<<"$1"
}

# Count latest-per-(name,source) check-runs that have not finished yet.
check_runs_incomplete_count() {
  jq -r "$_ci_jq_latest"'
    latest_per_name | map(select(.status != "completed")) | length
  ' <<<"$1"
}

# "name: conclusion" for each latest-per-(name,source) completed check-run whose
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
# print those NOT yet present-and-completed: absent from the commit, or ANY of
# their runs (across sources) not yet completed. Empty output = every required
# name has at least one run and all its runs have completed.
required_checks_pending() {
  jq -r --arg req "$2" "$_ci_jq_latest"'
    (latest_per_name) as $runs
    | ($req | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0)))[]
    | . as $name
    | ([ $runs[] | select(.name == $name) ]) as $entries
    | select( ($entries | length) == 0 or ($entries | any(.status != "completed")) )
  ' <<<"$1"
}

# Of the comma-separated required names in $2 (surrounding whitespace trimmed),
# print "name: reason" for each that is absent ("missing") or has ANY completed
# run (across sources) whose conclusion is not acceptable. Empty output = every
# required name is present and all its runs passed.
required_checks_failures() {
  jq -r --arg req "$2" --argjson ok "$CI_OK_CONCLUSIONS" "$_ci_jq_latest"'
    (latest_per_name) as $runs
    | ($req | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0)))[]
    | . as $name
    | ([ $runs[] | select(.name == $name) ]) as $entries
    | if ($entries | length) == 0 then "\($name): missing"
      else
        ([ $entries[] | select(.status == "completed") | select(.conclusion as $c | ($ok | index($c)) | not) ]) as $bad
        | if ($bad | length) > 0 then "\($name): \($bad[0].conclusion // "incomplete")" else empty end
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
