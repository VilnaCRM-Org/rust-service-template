#!/usr/bin/env bats
# Tests of the targets that are not gates and of the surface behaviour, with their negative tests
# (architecture-delivery.md "CLI Tests (Bats)", file make_general.bats).

bats_require_minimum_version 1.8.0
load test_helper

# bats file_tags=surface

setup() {
  _common_setup
  tmp="$(mktemp -d)"
}

teardown() {
  restore_planted
  [[ -z "${tmp:-}" ]] || rm -rf -- "${tmp}"
}

# Runs the assistant hook with the path of an edit on standard input.
run_hook() {
  local mode="$1" path="$2"
  run bash -c 'jq -n --arg path "$2" "{tool_input: {file_path: \$path}}" | CLAUDE_PROJECT_DIR="$3" scripts/claude/guard-protected-files.sh "$1"' \
    _ "${mode}" "${path}" "${REPO_ROOT}"
}

# --- help and doctor ---------------------------------------------------------------------------------------

@test "make with no target prints the three header lines" {
  run make --no-print-directory
  assert_success
  assert_line --index 0 'Usage:'
  assert_line --index 1 '  make [target] [arg="val"...]'
  assert_line --index 2 'Targets:'
}

@test "make help prints the three header lines and the same text as make" {
  run make --no-print-directory help
  assert_success
  assert_line --index 0 'Usage:'
  assert_line --index 1 '  make [target] [arg="val"...]'
  assert_line --index 2 'Targets:'
  local default
  default="$(make --no-print-directory)"
  assert_equal "${output}" "${default}"
}

@test "every target of the Makefile database has a help line" {
  local targets helped missing
  targets="$(make -pRrq : 2>/dev/null | awk -F: '/^[a-zA-Z0-9][^$#\/\t=]*:([^=]|$)/ {print $1}' | grep -vx 'Makefile' | sort -u)"
  helped="$(make --no-print-directory help | awk 'NR>3 {print $1}' | sort -u)"
  [[ -n "${targets}" ]]
  missing="$(comm -23 <(printf '%s\n' "${targets}") <(printf '%s\n' "${helped}"))"
  assert_equal "${missing}" ""
}

@test "make doctor passes and prints the platform line first" {
  run make --no-print-directory doctor
  assert_success
  assert_line --index 0 --regexp '^Platform: [a-z0-9]+/[A-Za-z0-9_]+ \((verified in CI|not verified in CI)\)$'
  refute_output --partial '[MISSING]'
  refute_output --partial '[OUTDATED]'
}

# --- the aggregate ---------------------------------------------------------------------------------------------

@test "make ci-list equals the verification block of AGENTS.md" {
  local listed block
  listed="$(make --no-print-directory ci-list)"
  block="$(awk '/<!-- verification:start -->/ {on = 1; next} /<!-- verification:end -->/ {on = 0} on' AGENTS.md |
    awk '/^[`][`][`]/ {next} /^make / {sub(/^make /, ""); print}')"
  [[ -n "${block}" ]]
  assert_equal "${listed}" "${block}"
}

@test "make -n ci shows the seven stages in order" {
  run make -n ci
  assert_success
  # shellcheck disable=SC2016 # the dollar sign belongs to the recipe text
  assert_line 'for stage in ci-preflight ci-static-analysis ci-tests ci-contracts ci-mutation ci-delivery ci-cli; do make --no-print-directory $stage; done'
  # The first gate of every stage, in the order of the stages.
  local gates=(validate-configuration format-check setup-test-db validate-contract-snapshots mutation-tests-diff build-prod-image bats)
  local previous=0 gate line
  for gate in "${gates[@]}"; do
    line="$(awk -v gate="make --no-print-directory ${gate}" '$0 == gate {print NR; exit}' <<<"${output}")"
    [[ -n "${line}" ]] || fail "the dry run of make ci does not start ${gate}"
    [[ "${line}" -gt "${previous}" ]] || fail "${gate} is out of order"
    previous="${line}"
  done
}

@test "make ci CI_STAGES=help prints the success line" {
  run make --no-print-directory ci CI_STAGES=help
  assert_success
  assert_line 'CI checks successfully passed!'
  assert_output --partial 'Usage:'
}

@test "make purge removes a planted report and keeps target/debug" {
  # The recipe runs in a copy of the build files, so that no report of a developer is deleted.
  mkdir -p "${tmp}/target/debug" "${tmp}/target/reports/planted"
  : >"${tmp}/target/debug/kept"
  : >"${tmp}/target/reports/planted/report.txt"
  cp -r Makefile make "${tmp}/"
  run make --no-print-directory -C "${tmp}" purge
  assert_success
  assert_file_not_exists "${tmp}/target/reports/planted/report.txt"
  assert_dir_not_exists "${tmp}/target/reports"
  assert_file_exists "${tmp}/target/debug/kept"
}

@test "scripts/doctor.sh with a reduced PATH exits 1 and reports the missing cargo" {
  local tool path
  mkdir -p "${tmp}/bin"
  for tool in bash sed grep head sort uname tr dirname cat; do
    path="$(command -v "${tool}")"
    ln -s "${path}" "${tmp}/bin/${tool}"
  done
  run env -i PATH="${tmp}/bin" HOME="${tmp}" "$(command -v bash)" scripts/doctor.sh
  assert_failure 1
  assert_line --partial '[MISSING] cargo:'
}

@test "make ci with a planted protected change fails without the success line" {
  require_command cargo
  printf '\n# planted by a Bats test\n' >"${tmp}/comment.txt"
  plant_append clippy.toml "${tmp}/comment.txt"
  run make --no-print-directory ci CI_STAGES=validate-configuration base_ref=HEAD
  assert_failure
  assert_output --partial 'Modification of locked configuration file is not allowed: clippy.toml'
  refute_output --partial 'CI checks successfully passed!'
}

# --- the assistant hook -------------------------------------------------------------------------------------------

@test "the assistant hook allows an unprotected path" {
  require_command jq
  require_command cargo
  run_hook pre "${REPO_ROOT}/README.md"
  assert_success
  refute_output --partial 'Protected quality configuration'
}

@test "the assistant hook allows a protected path with ALLOW_PROTECTED_CONFIG_EDIT=1" {
  require_command jq
  ALLOW_PROTECTED_CONFIG_EDIT=1 run_hook pre "${REPO_ROOT}/clippy.toml"
  assert_success
  assert_output --partial 'ALLOW_PROTECTED_CONFIG_EDIT=1 is set'
}

@test "the assistant hook allows the edit of a dependency line in the root Cargo.toml" {
  require_command jq
  require_command cargo
  run_hook pre "${REPO_ROOT}/Cargo.toml"
  assert_success
  sed 's/^\(serde_json = "\)[^"]*"$/\1>=0.0.1"/' Cargo.toml >"${tmp}/edited.toml"
  run ! cmp -s Cargo.toml "${tmp}/edited.toml"
  plant_replace Cargo.toml "${tmp}/edited.toml"
  run_hook post "${REPO_ROOT}/Cargo.toml"
  assert_success
  assert_file_contains Cargo.toml '^serde_json = ">=0.0.1"$'
}

@test "the assistant hook refuses an edit of clippy.toml before it happens" {
  require_command jq
  require_command cargo
  run_hook pre "${REPO_ROOT}/clippy.toml"
  assert_failure 2
  assert_output --partial 'Protected quality configuration: clippy.toml.'
  assert_output --partial 'ALLOW_PROTECTED_CONFIG_EDIT=1'
}

@test "the assistant hook undoes the edit of a lint level in the root Cargo.toml" {
  require_command jq
  require_command cargo
  run_hook pre "${REPO_ROOT}/Cargo.toml"
  assert_success
  sed 's/^unwrap_used = "warn"/unwrap_used = "allow"/' Cargo.toml >"${tmp}/edited.toml"
  run ! cmp -s Cargo.toml "${tmp}/edited.toml"
  plant_replace Cargo.toml "${tmp}/edited.toml"
  assert_file_contains Cargo.toml '^unwrap_used = "allow"'
  run_hook post "${REPO_ROOT}/Cargo.toml"
  assert_failure 2
  assert_output --partial 'The edit was undone'
  assert_output --partial 'Protected quality configuration: Cargo.toml.'
  assert_file_contains Cargo.toml '^unwrap_used = "warn"'
  run git diff --quiet -- Cargo.toml
  assert_success
}

# --- G16: the negative test of the Bats gate ------------------------------------------------------------------------

@test "G16: make bats fails on a copy of the failing fixture suite" {
  require_docker
  cp tests/CLI/bats/fixtures/failing_suite/failing.bats.txt "${tmp}/failing.bats"
  run make --no-print-directory bats BATS_PATH="${tmp}"
  assert_failure
  assert_output --partial 'not ok 1 a planted failure is reported'
}

# --- the harness itself ------------------------------------------------------------------------------------------------

@test "restore_planted restores appended, replaced, kept and new files, and repairs a leftover" {
  local original_cargo_lock
  original_cargo_lock="$(git hash-object Cargo.lock)"
  printf '\n# planted\n' >"${tmp}/fixture.txt"
  plant_append clippy.toml "${tmp}/fixture.txt"
  plant_replace rustfmt.toml "${tmp}/fixture.txt"
  plant_keep Cargo.lock
  printf 'rewritten by a tool\n' >Cargo.lock
  plant_new tests/CLI/bats/planted-dir/planted.txt "${tmp}/fixture.txt"
  assert_file_exists tests/CLI/bats/planted-dir/planted.txt
  run git status --porcelain -- clippy.toml rustfmt.toml Cargo.lock
  assert_output --partial 'clippy.toml'
  assert_file_exists target/bats-restore/manifest
  # A second plant of the same file keeps the first backup.
  plant_append clippy.toml "${tmp}/fixture.txt"
  # The next test of an interrupted run starts with _common_setup, which repairs the tree.
  _common_setup
  assert_file_not_exists tests/CLI/bats/planted-dir/planted.txt
  assert_dir_not_exists tests/CLI/bats/planted-dir
  assert_dir_not_exists target/bats-restore
  assert_equal "$(git hash-object Cargo.lock)" "${original_cargo_lock}"
  run git status --porcelain -- clippy.toml rustfmt.toml Cargo.lock
  assert_output ''
}

@test "require_command skips with a reason" {
  run bash -c 'source tests/CLI/bats/test_helper.bash; skip() { echo "skipped: $*"; return 0; }; require_command no-such-command-anywhere'
  assert_output 'skipped: the command '"'"'no-such-command-anywhere'"'"' is required'
  run bash -c 'source tests/CLI/bats/test_helper.bash; skip() { echo "skipped: $*"; return 0; }; DOCKER=/nonexistent require_docker'
  assert_output 'skipped: a reachable container engine (docker) is required'
}
