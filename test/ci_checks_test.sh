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

echo "# GraphQL statusCheckRollup: validity + normalization into the check-run model"
ROLLUP_MIXED='{"data":{"repository":{"object":{"statusCheckRollup":{"state":"PENDING","contexts":{"nodes":[
  {"__typename":"CheckRun","name":"e2e","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-07-02T17:07:17Z","databaseId":3},
  {"__typename":"CheckRun","name":"test","status":"IN_PROGRESS","conclusion":null,"startedAt":"2026-07-02T17:07:15Z","databaseId":4},
  {"__typename":"StatusContext","context":"buildkite/packmanager","state":"SUCCESS","createdAt":"2026-07-02T17:07:07Z"}]}}}}}}'
ROLLUP_STATUS_FAIL='{"data":{"repository":{"object":{"statusCheckRollup":{"contexts":{"nodes":[
  {"__typename":"StatusContext","context":"buildkite/packmanager","state":"FAILURE","createdAt":"2026-07-02T17:07:07Z"}]}}}}}}'
ROLLUP_NULL='{"data":{"repository":{"object":{"statusCheckRollup":null}}}}'
ROLLUP_ERROR='{"errors":[{"message":"Something went wrong"}]}'
ROLLUP_NOOBJECT='{"data":{"repository":{"object":null}}}'

assert_ok    "mixed rollup is valid"        rollup_payload_valid "$ROLLUP_MIXED"
assert_ok    "null rollup (commit, no checks) is valid" rollup_payload_valid "$ROLLUP_NULL"
assert_notok "errors payload invalid"       rollup_payload_valid "$ROLLUP_ERROR"
assert_notok "unresolved commit invalid"    rollup_payload_valid "$ROLLUP_NOOBJECT"

# Legacy status + check-runs evaluated uniformly after normalization.
assert_eq "normalized: 1 incomplete (test in_progress)" "1" \
  "$(check_runs_incomplete_count "$(normalize_rollup "$ROLLUP_MIXED")")"
assert_eq "normalized: no failures" "" \
  "$(check_runs_failures "$(normalize_rollup "$ROLLUP_MIXED")")"
assert_eq "normalized: buildkite (a StatusContext) satisfies a required name" "" \
  "$(required_checks_pending "$(normalize_rollup "$ROLLUP_MIXED")" "buildkite/packmanager,e2e")"
assert_eq "normalized: in-progress required still pending" "test" \
  "$(required_checks_pending "$(normalize_rollup "$ROLLUP_MIXED")" "test")"
assert_eq "normalized: absent required still pending" "client_test" \
  "$(required_checks_pending "$(normalize_rollup "$ROLLUP_MIXED")" "client_test")"
assert_eq "normalized: a FAILURE legacy status is a failure" "buildkite/packmanager: failure" \
  "$(check_runs_failures "$(normalize_rollup "$ROLLUP_STATUS_FAIL")")"
assert_eq "normalized: required legacy status failure reported" "buildkite/packmanager: failure" \
  "$(required_checks_failures "$(normalize_rollup "$ROLLUP_STATUS_FAIL")" "buildkite/packmanager")"
assert_eq "normalized null rollup: 0 incomplete" "0" \
  "$(check_runs_incomplete_count "$(normalize_rollup "$ROLLUP_NULL")")"

echo "# same name from two sources is not collapsed (bugs 1 & 2)"
# Two check-runs named "build" from different apps: one fails, one passes.
ROLLUP_TWO_APPS='{"data":{"repository":{"object":{"statusCheckRollup":{"contexts":{"nodes":[
  {"__typename":"CheckRun","name":"build","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-07-02T10:00:00Z","databaseId":50,"checkSuite":{"app":{"databaseId":111}}},
  {"__typename":"CheckRun","name":"build","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-07-02T10:01:00Z","databaseId":100,"checkSuite":{"app":{"databaseId":222}}}]}}}}}}'
# A legacy status "test" (FAILURE) alongside an Actions check-run "test" (SUCCESS).
ROLLUP_STATUS_VS_CHECK='{"data":{"repository":{"object":{"statusCheckRollup":{"contexts":{"nodes":[
  {"__typename":"CheckRun","name":"test","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-07-02T10:00:00Z","databaseId":5,"checkSuite":{"app":{"databaseId":15368}}},
  {"__typename":"StatusContext","context":"test","state":"FAILURE","createdAt":"2026-07-02T11:00:00Z"}]}}}}}}'
assert_eq "two apps same name: failing app not masked" "build: failure" \
  "$(check_runs_failures "$(normalize_rollup "$ROLLUP_TWO_APPS")")"
assert_eq "two apps same name: required build fails"    "build: failure" \
  "$(required_checks_failures "$(normalize_rollup "$ROLLUP_TWO_APPS")" "build")"
assert_eq "status vs check same name: failing status not masked" "test: failure" \
  "$(check_runs_failures "$(normalize_rollup "$ROLLUP_STATUS_VS_CHECK")")"
assert_eq "status vs check same name: required test fails" "test: failure" \
  "$(required_checks_failures "$(normalize_rollup "$ROLLUP_STATUS_VS_CHECK")" "test")"

echo "# any_path_has_prefix"
FILES_MIXED=$'SensrTrxMES/app/x.js\nPackManager/db/schema.rb'
FILES_PM_ONLY=$'PackManager/db/schema.rb\n.github/workflows/integrate.yml'
assert_ok    "matches SensrTrxMES/ prefix"        any_path_has_prefix "$FILES_MIXED"   "SensrTrxMES/"
assert_notok "PM-only does not match SensrTrxMES/" any_path_has_prefix "$FILES_PM_ONLY" "SensrTrxMES/"
assert_ok    "matches one of several prefixes"    any_path_has_prefix "$FILES_PM_ONLY" "SensrTrxMES/,PackManager/"
assert_notok "empty prefix list never matches"    any_path_has_prefix "$FILES_MIXED"   ""
assert_notok "prefix respects the trailing slash" any_path_has_prefix $'SensrTrxMESX/x.js' "SensrTrxMES/"

exit $fail
