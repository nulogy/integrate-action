#!/usr/bin/env bash
# Zero-dependency tests for ci_checks.sh (needs bash + jq). Run: bash test/ci_checks_test.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
source ./ci_checks.sh

fail=0
assert_eq() { # $1=desc $2=expected $3=actual
  if [[ "$2" == "$3" ]]; then echo "ok   - $1"
  else echo "FAIL - $1"; echo "       expected: [$2]"; echo "       actual:   [$3]"; fail=1; fi
}

ALL_GREEN='{"total_count":4,"check_runs":[
  {"name":"test","status":"completed","conclusion":"success"},
  {"name":"e2e","status":"completed","conclusion":"success"},
  {"name":"client_test","status":"completed","conclusion":"success"},
  {"name":"auto-merge","status":"completed","conclusion":"skipped"}]}'
RUNNING='{"total_count":2,"check_runs":[
  {"name":"test","status":"completed","conclusion":"success"},
  {"name":"e2e","status":"in_progress","conclusion":null}]}'
FAILED='{"total_count":2,"check_runs":[
  {"name":"test","status":"completed","conclusion":"success"},
  {"name":"e2e","status":"completed","conclusion":"failure"}]}'
CANCELLED='{"total_count":1,"check_runs":[
  {"name":"e2e","status":"completed","conclusion":"cancelled"}]}'
NULL_CONCL='{"total_count":1,"check_runs":[
  {"name":"weird","status":"completed","conclusion":null}]}'
NEUTRAL='{"total_count":1,"check_runs":[
  {"name":"advisory","status":"completed","conclusion":"neutral"}]}'
EMPTY='{"total_count":0,"check_runs":[]}'

assert_eq "all green: 0 incomplete"      "0" "$(check_runs_incomplete_count "$ALL_GREEN")"
assert_eq "all green: no failures"       ""  "$(check_runs_failures "$ALL_GREEN")"
assert_eq "running: 1 incomplete"        "1" "$(check_runs_incomplete_count "$RUNNING")"
assert_eq "failed: e2e reported"         "e2e: failure"   "$(check_runs_failures "$FAILED")"
assert_eq "cancelled: e2e reported"      "e2e: cancelled" "$(check_runs_failures "$CANCELLED")"
assert_eq "null conclusion is a failure" "weird: none"    "$(check_runs_failures "$NULL_CONCL")"
assert_eq "neutral passes"               ""  "$(check_runs_failures "$NEUTRAL")"
assert_eq "empty: 0 incomplete"          "0" "$(check_runs_incomplete_count "$EMPTY")"
assert_eq "empty: no failures"           ""  "$(check_runs_failures "$EMPTY")"

exit $fail
