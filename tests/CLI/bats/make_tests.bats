#!/usr/bin/env bats
# Tests of the test-level targets and their negative tests (architecture-delivery.md "CLI Tests (Bats)", file
# make_tests.bats): gates G11 to G15 and G30, and the `setup-test-db` target.
#
# Every plant goes into the leaf crate `xtask`, into `features/` or into `.sqlx/`, so only little is rebuilt. Make
# reports every failed recipe with its own status 2, so these tests assert "non-zero" and the tool's own output.

bats_require_minimum_version 1.8.0
load test_helper

# bats file_tags=tests

setup() {
  _common_setup
}

teardown() {
  restore_planted
  if [[ -n "${marker_table:-}" ]]; then
    dev_sql "drop table if exists ${marker_table}" >/dev/null 2>&1 || true
  fi
}

# Runs a statement against the development database `app` in the database container of the compose project.
dev_sql() {
  "${DOCKER:-docker}" compose exec -T database psql --quiet --no-psqlrc --tuples-only --no-align -U app -d app -c "$1"
}

# --- setup-test-db -----------------------------------------------------------------------------------------

@test "setup-test-db creates app_test and leaves the development database untouched" {
  require_docker
  marker_table="bats_marker_$$"
  run make --no-print-directory ensure-database
  assert_success
  run dev_sql "create table ${marker_table} (id integer); insert into ${marker_table} values (7)"
  assert_success

  run make --no-print-directory setup-test-db
  assert_success

  run "${DOCKER:-docker}" compose exec -T database psql --quiet --no-psqlrc --tuples-only --no-align -U app -d postgres \
    -c "select count(*) from pg_database where datname = 'app_test'"
  assert_success
  assert_output '1'
  run dev_sql "select id from ${marker_table}"
  assert_success
  assert_output '7'
}

# --- G11: unit tests ---------------------------------------------------------------------------------------

@test "G11: a failing unit test makes unit-tests fail" {
  plant_append xtask/src/cli/tests.rs "${BATS_TEST_DIRNAME}/fixtures/failing_unit_test.rs.txt"
  run make --no-print-directory unit-tests
  assert_failure
  assert_output --partial 'planted_failing_unit_test'
}

# --- G12: integration tests --------------------------------------------------------------------------------

# bats test_tags=slow
@test "G12: a failing integration test makes integration-tests fail" {
  require_docker
  plant_append xtask/tests/integration/main.rs "${BATS_TEST_DIRNAME}/fixtures/failing_integration_test.rs.txt"
  run make --no-print-directory integration-tests
  assert_failure
  assert_output --partial 'planted_failing_integration_test'
}

# --- G13: end-to-end tests ---------------------------------------------------------------------------------

# bats test_tags=slow
@test "G13: a feature with an undefined step makes e2e-tests fail with the unmatched step" {
  require_docker
  plant_new features/planted_undefined_step.feature "${BATS_TEST_DIRNAME}/fixtures/undefined_step.feature.txt"
  run make --no-print-directory e2e-tests
  assert_failure
  assert_output --partial "Step doesn't match any function"
}

# --- G14: coverage -----------------------------------------------------------------------------------------

# bats test_tags=slow
@test "G14: an uncovered function makes tests-with-coverage fail and is listed with a zero count" {
  require_docker
  plant_append xtask/src/cli.rs "${BATS_TEST_DIRNAME}/fixtures/uncovered_function.rs.txt"
  rm -f target/coverage/lcov.info
  run make --no-print-directory tests-with-coverage
  assert_failure
  assert_file_exists target/coverage/lcov.info
  run grep -E '^FNDA:0,.*planted' target/coverage/lcov.info
  assert_success
}

# --- G15: mutation testing of the changed code -------------------------------------------------------------

# bats test_tags=slow
@test "G15: a function whose tests miss a mutant makes mutation-tests-diff fail with a MISSED line" {
  require_docker
  require_command cargo-mutants
  plant_append xtask/src/cli.rs "${BATS_TEST_DIRNAME}/fixtures/uncovered_function.rs.txt"
  CI=true run make --no-print-directory mutation-tests-diff base_ref=HEAD
  assert_failure
  assert_output --regexp 'MISSED +xtask/src/cli\.rs:[0-9]+:[0-9]+: replace planted -> bool with true'
  assert_output --partial 'mutation-tests-diff] Error 2'
  rm -rf mutants.out mutants.out.old
}

@test "G15: mutation-tests-diff with a base ref that does not exist fails with the base-ref message" {
  require_docker
  run make --no-print-directory mutation-tests-diff base_ref=no-such-ref
  assert_failure
  assert_output --partial 'mutation-tests-diff could not run: base ref no-such-ref is not available'
  assert_output --partial 'mutation-tests-diff] Error 2'
}

@test "G15: the script exits 2 for a base ref that does not exist and without the separator" {
  run scripts/mutation-diff.sh no-such-ref -- true
  assert_failure 2
  assert_output 'mutation-tests-diff could not run: base ref no-such-ref is not available'
  run scripts/mutation-diff.sh HEAD true
  assert_failure 2
  assert_output --partial 'mutation-tests-diff could not run: Usage:'
}

@test "G15: an empty diff passes without running the mutation command and counts zero mutants" {
  git diff --quiet HEAD -- '*.rs' || skip "the working tree has uncommitted Rust changes, so the diff is not empty"
  run scripts/mutation-diff.sh HEAD -- false
  assert_success
  assert_output --partial 'holds no production Rust change'
  run --separate-stderr scripts/mutation-diff.sh HEAD --list -- false
  assert_success
  assert_output '0'
}

@test "G15: the script appends the diff file and, with --list, prints only the number of lines the command lists" {
  plant_append xtask/src/cli.rs "${BATS_TEST_DIRNAME}/fixtures/uncovered_function.rs.txt"
  run scripts/mutation-diff.sh HEAD -- printf '%s\n'
  assert_success
  assert_output '--in-diff'$'\n''target/mutants.diff'
  assert_file_not_empty target/mutants.diff
  run --separate-stderr scripts/mutation-diff.sh HEAD --list -- printf '%s\n' one two
  assert_success
  assert_output '5'
}

# --- G30: query metadata -----------------------------------------------------------------------------------

# bats test_tags=slow
@test "G30: a missing file of .sqlx makes validate-sqlx-metadata fail" {
  require_docker
  local -a files=(.sqlx/query-*.json)
  plant_keep "${files[0]}"
  rm -- "${files[0]}"
  run make --no-print-directory validate-sqlx-metadata
  assert_failure
  assert_output --partial '.sqlx is missing one or more queries'
}
