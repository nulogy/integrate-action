#!/usr/bin/env bash
# Pure helpers for evaluating CI state on a commit. No network, no globals:
# every input is an argument, so these are unit-testable with fixtures.

# Check-run conclusions we treat as passing. Anything else on a completed run
# (failure, timed_out, cancelled, action_required, stale, or null/unknown)
# blocks the merge.
CI_OK_CONCLUSIONS='["success","neutral","skipped"]'

# Count check-runs not yet finished. $1 = /commits/{sha}/check-runs payload.
check_runs_incomplete_count() {
  jq -r '[.check_runs[] | select(.status != "completed")] | length' <<<"$1"
}

# "name: conclusion" for each completed check-run whose conclusion is not
# acceptable. Empty output = all completed runs passed. $1 = same payload.
check_runs_failures() {
  jq -r --argjson ok "$CI_OK_CONCLUSIONS" \
    '.check_runs[]
       | select(.status == "completed")
       | select(.conclusion as $c | ($ok | index($c)) | not)
       | "\(.name): \(.conclusion // "none")"' <<<"$1"
}
