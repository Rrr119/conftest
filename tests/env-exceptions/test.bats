#!/usr/bin/env bats

# Acceptance coverage for environment/resource scoped exceptions with expiry
# and identifiable output. The detailed assertions live in the example bundle
# so they can also be executed without bats.

setup() {
  EXAMPLE_DIR="$BATS_TEST_DIRNAME/../../examples/env-exceptions"
  if [ -z "${CONFTEST:-}" ]; then
    CONFTEST="$BATS_TEST_DIRNAME/../../conftest"
  fi
}

@test "scoped exceptions pass the three environment acceptance matrix" {
  run env CONFTEST="$CONFTEST" bash "$EXAMPLE_DIR/acceptance.sh"

  echo "$output"
  [ "$status" -eq 0 ]
}

@test "dev only reports the dev exception" {
  run "$CONFTEST" test -p "$EXAMPLE_DIR/policy" --env dev --no-color "$EXAMPLE_DIR/workloads.yaml"

  [ "$status" -eq 1 ]
  [[ "$output" =~ "[EX-DEV-DEBUG-001]" ]]
  [[ ! "$output" =~ "EX-PROD-MONITOR-004" ]]
  [[ ! "$output" =~ "EX-EXPIRED-BATCH-900" ]]
}

@test "prod reports the prod exception and keeps strict failures" {
  run "$CONFTEST" test -p "$EXAMPLE_DIR/policy" --env prod --no-color "$EXAMPLE_DIR/workloads.yaml"

  [ "$status" -eq 1 ]
  [[ "$output" =~ "[EX-PROD-MONITOR-004]" ]]
  [[ ! "$output" =~ "EX-DEV-DEBUG-001" ]]
}

@test "expired exceptions stop applying after their expiry" {
  run env CONFTEST_EXCEPTION_NOW=2100-01-01T00:00:00Z \
    "$CONFTEST" test -p "$EXAMPLE_DIR/policy" --env dev --no-color "$EXAMPLE_DIR/workloads.yaml"

  [ "$status" -eq 1 ]
  [[ ! "$output" =~ "EX-DEV-DEBUG-001" ]]
  [[ "$output" =~ "5 failures" ]]
}
