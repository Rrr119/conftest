#!/usr/bin/env bash
# Acceptance checks for environment/resource scoped, expiring exceptions.
#
# Usage:
#   CONFTEST=/path/to/conftest ./acceptance.sh
# or just:
#   ./acceptance.sh   # falls back to "conftest" on PATH
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

CONFTEST_BIN="${CONFTEST:-conftest}"
if ! command -v "$CONFTEST_BIN" >/dev/null 2>&1 && [ ! -x "$CONFTEST_BIN" ]; then
  echo "ERROR: conftest binary not found. Set CONFTEST=/path/to/conftest" >&2
  exit 2
fi

POLICY_DIR="policy"
INPUT="workloads.yaml"
FAILED=0
CHECKS=0

pass() {
  CHECKS=$((CHECKS + 1))
  echo "  PASS: $1"
}

fail() {
  CHECKS=$((CHECKS + 1))
  FAILED=1
  echo "  FAIL: $1" >&2
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass "$desc (= $actual)"
  else
    fail "$desc (expected '$expected', got '$actual')"
  fi
}

# json_for <env> [extra conftest args...] -> prints the JSON report on stdout.
json_for() {
  local env="$1"; shift
  "$CONFTEST_BIN" test -p "$POLICY_DIR" --env "$env" -o json "$@" "$INPUT" 2>/dev/null || true
}

echo "== Three environments: scope matrix =="

# env|expected failures|expected exceptions|expected ids (comma separated)
MATRIX=(
  "dev|3|2|EX-DEV-DEBUG-001"
  "staging|3|2|EX-STG-DEBUG-ROOT-002,EX-STG-LEGACY-003"
  "prod|4|1|EX-PROD-MONITOR-004"
)

for row in "${MATRIX[@]}"; do
  IFS='|' read -r env want_fail want_exc want_ids <<<"$row"
  echo "-- environment: $env --"

  json="$(json_for "$env")"
  got_fail="$(printf '%s' "$json" | jq '.[0].failures | length')"
  got_exc="$(printf '%s' "$json" | jq '.[0].exceptions | length')"
  assert_eq "[$env] failure count" "$want_fail" "$got_fail"
  assert_eq "[$env] exception count" "$want_exc" "$got_exc"

  ids="$(printf '%s' "$json" | jq -r '.[0].exceptions[].metadata.id' | sort -u | tr '\n' ',' | sed 's/,$//')"
  # Expected ids may be in any order.
  IFS=',' read -ra expected_id_list <<<"$want_ids"
  for id in "${expected_id_list[@]}"; do
    if printf '%s' "$ids" | grep -q "$id"; then
      pass "[$env] reports hit exception $id"
    else
      fail "[$env] expected hit exception $id, got ids: $ids"
    fi
  done

  # Expired exception must never be reported as applied.
  if printf '%s' "$json" | jq -e '.[0].exceptions[] | select(.metadata.id == "EX-EXPIRED-BATCH-900")' >/dev/null; then
    fail "[$env] expired exception EX-EXPIRED-BATCH-900 must not apply"
  else
    pass "[$env] expired exception is not applied"
  fi

  # batch-job violation (the expired target) must remain a failure everywhere.
  if printf '%s' "$json" | jq -e '.[0].failures[].msg | select(test("batch-job"))' >/dev/null; then
    pass "[$env] batch-job failure remains (expired exception ineffective)"
  else
    fail "[$env] batch-job should still fail"
  fi
done

echo "== Resource scope inside dev =="
dev_json="$(json_for dev)"
for resource in batch-job legacy-agent node-monitor; do
  if printf '%s' "$dev_json" | jq -e --arg r "$resource" '.[0].failures[].msg | select(test($r))' >/dev/null; then
    pass "[dev] EX-DEV-DEBUG-001 does not cover $resource"
  else
    fail "[dev] expected $resource to fail (resource scope leaked)"
  fi
done
if printf '%s' "$dev_json" | jq -e '.[0].failures[].msg | select(test("debug-shell"))' >/dev/null; then
  fail "[dev] debug-shell should be fully excepted by EX-DEV-DEBUG-001"
else
  pass "[dev] debug-shell is excepted for both targeted rules"
fi

echo "== Rule scope inside staging =="
stg_json="$(json_for staging)"
if printf '%s' "$stg_json" | jq -e '.[0].failures[].msg | select(test("debug-shell.*privileged"))' >/dev/null; then
  pass "[staging] run_as_root-only exception does not cover privileged"
else
  fail "[staging] debug-shell privileged should still fail"
fi

echo "== Human output identifies the hit exception =="
standard="$("$CONFTEST_BIN" test -p "$POLICY_DIR" --env prod --no-color "$INPUT" 2>&1 || true)"
if grep -q 'EXCP .*\[EX-PROD-MONITOR-004\]' <<<"$standard"; then
  pass "standard output line contains [EX-PROD-MONITOR-004]"
else
  fail "standard output did not identify the exception: $standard"
fi
if grep -q 'environment=prod' <<<"$standard"; then
  pass "standard output shows the resolved environment"
else
  fail "standard output missing environment marker"
fi

echo "== Expiration is time driven =="
future_json="$(CONFTEST_EXCEPTION_NOW=2100-01-01T00:00:00Z "$CONFTEST_BIN" test -p "$POLICY_DIR" --env dev -o json "$INPUT" 2>/dev/null || true)"
future_exc="$(printf '%s' "$future_json" | jq '.[0].exceptions | length')"
assert_eq "[clock=2100] all dated exceptions expired" "0" "$future_exc"

noon_json="$(CONFTEST_EXCEPTION_NOW=2099-12-31T12:00:00Z "$CONFTEST_BIN" test -p "$POLICY_DIR" --env dev -o json "$INPUT" 2>/dev/null || true)"
noon_exc="$(printf '%s' "$noon_json" | jq '.[0].exceptions | length')"
assert_eq "[clock=expiry-day-noon] exception still active" "2" "$noon_exc"

echo "== External --data registry is compatible =="
ext_json="$("$CONFTEST_BIN" test -p "$POLICY_DIR" -d exceptions.yaml -d env/staging.yaml -o json "$INPUT" 2>/dev/null || true)"
ext_exc="$(printf '%s' "$ext_json" | jq '.[0].exceptions | length')"
ext_fail="$(printf '%s' "$ext_json" | jq '.[0].failures | length')"
assert_eq "[external data] staging exceptions" "2" "$ext_exc"
assert_eq "[external data] staging failures" "3" "$ext_fail"

echo
if [ "$FAILED" -ne 0 ]; then
  echo "ACCEPTANCE FAILED ($CHECKS checks)"
  exit 1
fi
echo "ACCEPTANCE PASSED ($CHECKS checks)"
