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
assert_ok() { # $1=desc ; runs $2.. as a command, expects exit 0
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "ok   - $desc"; else echo "FAIL - $desc (expected exit 0)"; fail=1; fi
}
assert_notok() { # $1=desc ; runs $2.. expects non-zero exit
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "FAIL - $desc (expected non-zero exit)"; fail=1; else echo "ok   - $desc"; fi
}

ALL_GREEN='{"total_count":4,"check_runs":[
  {"name":"test","status":"completed","conclusion":"success","started_at":"2026-07-02T17:07:15Z"},
  {"name":"e2e","status":"completed","conclusion":"success","started_at":"2026-07-02T17:07:17Z"},
  {"name":"client_test","status":"completed","conclusion":"success","started_at":"2026-07-02T17:07:15Z"},
  {"name":"auto-merge","status":"completed","conclusion":"skipped","started_at":"2026-07-02T17:07:10Z"}]}'
RUNNING='{"total_count":2,"check_runs":[
  {"name":"test","status":"completed","conclusion":"success","started_at":"2026-07-02T17:07:15Z"},
  {"name":"e2e","status":"in_progress","conclusion":null,"started_at":"2026-07-02T17:07:17Z"}]}'
FAILED='{"total_count":2,"check_runs":[
  {"name":"test","status":"completed","conclusion":"success","started_at":"2026-07-02T17:07:15Z"},
  {"name":"e2e","status":"completed","conclusion":"failure","started_at":"2026-07-02T17:07:17Z"}]}'
CANCELLED='{"total_count":1,"check_runs":[
  {"name":"e2e","status":"completed","conclusion":"cancelled","started_at":"2026-07-02T17:07:17Z"}]}'
NULL_CONCL='{"total_count":1,"check_runs":[
  {"name":"weird","status":"completed","conclusion":null,"started_at":"2026-07-02T17:07:17Z"}]}'
NEUTRAL='{"total_count":1,"check_runs":[
  {"name":"advisory","status":"completed","conclusion":"neutral","started_at":"2026-07-02T17:07:17Z"}]}'
EMPTY='{"total_count":0,"check_runs":[]}'
# A superseded run (older, cancelled) plus its rerun (newer, success) for the same name.
RERUN='{"total_count":2,"check_runs":[
  {"name":"e2e","status":"completed","conclusion":"cancelled","started_at":"2026-07-02T10:00:00Z"},
  {"name":"e2e","status":"completed","conclusion":"success","started_at":"2026-07-02T10:30:00Z"}]}'
# Same name, older success but newer run still running -> latest is incomplete.
RERUN_RUNNING='{"total_count":2,"check_runs":[
  {"name":"e2e","status":"completed","conclusion":"success","started_at":"2026-07-02T10:00:00Z"},
  {"name":"e2e","status":"in_progress","conclusion":null,"started_at":"2026-07-02T10:30:00Z"}]}'
ERROR_PAYLOAD='{"message":"Not Found","documentation_url":"https://docs.github.com/rest"}'

echo "# incomplete-count / failures (latest run per name)"
assert_eq "all green: 0 incomplete"      "0" "$(check_runs_incomplete_count "$ALL_GREEN")"
assert_eq "all green: no failures"       ""  "$(check_runs_failures "$ALL_GREEN")"
assert_eq "running: 1 incomplete"        "1" "$(check_runs_incomplete_count "$RUNNING")"
assert_eq "failed: e2e reported"         "e2e: failure"   "$(check_runs_failures "$FAILED")"
assert_eq "cancelled: e2e reported"      "e2e: cancelled" "$(check_runs_failures "$CANCELLED")"
assert_eq "null conclusion is a failure" "weird: none"    "$(check_runs_failures "$NULL_CONCL")"
assert_eq "neutral passes"               ""  "$(check_runs_failures "$NEUTRAL")"
assert_eq "empty: 0 incomplete"          "0" "$(check_runs_incomplete_count "$EMPTY")"
assert_eq "empty: no failures"           ""  "$(check_runs_failures "$EMPTY")"

echo "# reruns: only the latest run per name counts"
assert_eq "rerun success supersedes cancelled: no failures" "" "$(check_runs_failures "$RERUN")"
assert_eq "rerun success supersedes cancelled: 0 incomplete" "0" "$(check_runs_incomplete_count "$RERUN")"
assert_eq "rerun still running: 1 incomplete" "1" "$(check_runs_incomplete_count "$RERUN_RUNNING")"

echo "# payload validity guard"
assert_ok    "valid check-runs payload"  check_runs_payload_valid "$ALL_GREEN"
assert_ok    "empty check-runs payload valid" check_runs_payload_valid "$EMPTY"
assert_notok "error payload invalid"     check_runs_payload_valid "$ERROR_PAYLOAD"
assert_notok "empty string invalid"      check_runs_payload_valid ""

echo "# required_checks_pending (names absent or latest run not completed)"
assert_eq "required all present+completed: none pending" "" \
  "$(required_checks_pending "$ALL_GREEN" "test,client_test,e2e")"
assert_eq "required e2e still running: e2e pending" "e2e" \
  "$(required_checks_pending "$RUNNING" "test,e2e")"
assert_eq "required missing name reported pending" "missingcheck" \
  "$(required_checks_pending "$ALL_GREEN" "missingcheck")"
assert_eq "required rerun still running: e2e pending" "e2e" \
  "$(required_checks_pending "$RERUN_RUNNING" "e2e")"
assert_eq "empty required list: nothing pending" "" \
  "$(required_checks_pending "$ALL_GREEN" "")"

echo "# required_checks_failures (absent or bad-conclusion required names)"
assert_eq "required all green: no failures" "" \
  "$(required_checks_failures "$ALL_GREEN" "test,client_test,e2e")"
assert_eq "required missing: reported missing" "gone: missing" \
  "$(required_checks_failures "$ALL_GREEN" "gone")"
assert_eq "required failed: reported" "e2e: failure" \
  "$(required_checks_failures "$FAILED" "e2e")"
assert_eq "required cancelled (no rerun): reported" "e2e: cancelled" \
  "$(required_checks_failures "$CANCELLED" "e2e")"
assert_eq "required cancelled superseded by rerun success: no failure" "" \
  "$(required_checks_failures "$RERUN" "e2e")"
assert_eq "empty required list: no failures" "" \
  "$(required_checks_failures "$ALL_GREEN" "")"

echo "# required names tolerate surrounding whitespace"
assert_eq "spaces after commas: none pending" "" \
  "$(required_checks_pending "$ALL_GREEN" "test, client_test, e2e")"
assert_eq "spaces around names: no failures" "" \
  "$(required_checks_failures "$ALL_GREEN" " test ,client_test, e2e ")"

echo "# latest run per name is by id, so a newer run is never masked by an older one"
# Newer run (higher id) is still queued but has a null started_at.
RERUN_ID_QUEUED='{"total_count":2,"check_runs":[
  {"name":"e2e","status":"completed","conclusion":"success","started_at":"2026-07-02T10:00:00Z","id":100},
  {"name":"e2e","status":"queued","conclusion":null,"started_at":null,"id":200}]}'
# Newer run (higher id) completed as a failure, older as success.
RERUN_ID_FAILED='{"total_count":2,"check_runs":[
  {"name":"e2e","status":"completed","conclusion":"success","started_at":"2026-07-02T10:00:00Z","id":100},
  {"name":"e2e","status":"completed","conclusion":"failure","started_at":null,"id":200}]}'
assert_eq "newer queued run counts as incomplete" "1" "$(check_runs_incomplete_count "$RERUN_ID_QUEUED")"
assert_eq "newer queued run keeps required pending" "e2e" "$(required_checks_pending "$RERUN_ID_QUEUED" "e2e")"
assert_eq "newer failing run is not masked by older success" "e2e: failure" "$(check_runs_failures "$RERUN_ID_FAILED")"
assert_eq "newer failing required run reported" "e2e: failure" "$(required_checks_failures "$RERUN_ID_FAILED" "e2e")"

echo "# a null check-run name must not crash the required-checks gate"
NULL_NAME='{"total_count":2,"check_runs":[
  {"name":null,"status":"completed","conclusion":"failure","started_at":"2026-07-02T10:00:00Z","id":1},
  {"name":"e2e","status":"completed","conclusion":"success","started_at":"2026-07-02T10:00:00Z","id":2}]}'
assert_eq "null name ignored: none pending" "" "$(required_checks_pending "$NULL_NAME" "e2e")"
assert_eq "null name ignored: no failures" "" "$(required_checks_failures "$NULL_NAME" "e2e")"
assert_eq "null name ignored: 0 incomplete" "0" "$(check_runs_incomplete_count "$NULL_NAME")"

echo "# any_path_has_prefix"
FILES_MIXED=$'SensrTrxMES/app/x.js\nPackManager/db/schema.rb'
FILES_PM_ONLY=$'PackManager/db/schema.rb\n.github/workflows/integrate.yml'
assert_ok    "matches SensrTrxMES/ prefix"        any_path_has_prefix "$FILES_MIXED"   "SensrTrxMES/"
assert_notok "PM-only does not match SensrTrxMES/" any_path_has_prefix "$FILES_PM_ONLY" "SensrTrxMES/"
assert_ok    "matches one of several prefixes"    any_path_has_prefix "$FILES_PM_ONLY" "SensrTrxMES/,PackManager/"
assert_notok "empty prefix list never matches"    any_path_has_prefix "$FILES_MIXED"   ""
assert_notok "prefix respects the trailing slash" any_path_has_prefix $'SensrTrxMESX/x.js' "SensrTrxMES/"

exit $fail
