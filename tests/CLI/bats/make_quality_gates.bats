#!/usr/bin/env bats
# Tests of the static gates: the two passing runs that no other file covers and one negative test per gate and
# policy (architecture-delivery.md "CLI Tests (Bats)", DD-07, file make_quality_gates.bats).
#
# Every violation is planted in the leaf crate `xtask` (or in a protected file that no crate compiles), so only
# that crate is rebuilt, and is restored by teardown. Plants for G3 sit in plain functions, never in the body of
# an `#[async_trait]` method.

bats_require_minimum_version 1.8.0
load test_helper

# bats file_tags=quality

setup() {
  _common_setup
  tmp="$(mktemp -d)"
  tree_before="$(tree_status)"
}

teardown() {
  restore_planted
  [[ -z "${tmp:-}" ]] || rm -rf -- "${tmp}"
  # Whatever the test planted, the working tree is as it was.
  [[ -z "${tree_before+x}" ]] || [[ "$(tree_status)" == "${tree_before}" ]]
}

FIXTURES="${BATS_TEST_DIRNAME}/fixtures"

# --- passing runs that no other test repeats -----------------------------------------------------------------

# bats test_tags=slow
@test "pre-commit passes" {
  run make --no-print-directory pre-commit
  assert_success
}

@test "validate-configuration base_ref=HEAD passes a planted change when CONFIG_CHANGE_APPROVED=true" {
  printf '# planted by a test\n' >"${tmp}/comment.txt"
  plant_append clippy.toml "${tmp}/comment.txt"
  run env CONFIG_CHANGE_APPROVED=true make --no-print-directory validate-configuration base_ref=HEAD
  assert_success
  assert_output --partial '[APPROVED]'
  assert_output --partial 'clippy.toml'
}

# --- G1 to G4: formatting, static analysis, complexity, architecture ---------------------------------------

@test "G1: format-check reports the diff of unformatted lines" {
  plant_append xtask/src/main.rs "${FIXTURES}/badly_formatted.rs.txt"
  run make --no-print-directory format-check
  assert_failure
  assert_output --partial 'Diff in'
}

# bats test_tags=slow
@test "G2: static-analysis rejects an unwrap with unwrap_used" {
  plant_append xtask/src/main.rs "${FIXTURES}/unwrap_used.rs.txt"
  run make --no-print-directory static-analysis
  assert_failure
  assert_output --partial 'unwrap_used'
}

# bats test_tags=slow
@test "G2: static-analysis rejects a SystemTime::now() call with disallowed_methods" {
  plant_append xtask/src/main.rs "${FIXTURES}/banned_api.rs.txt"
  run make --no-print-directory static-analysis
  assert_failure
  assert_output --partial 'disallowed_methods'
}

# bats test_tags=slow
@test "G2: static-analysis rejects a suppression without a reason" {
  plant_append xtask/src/main.rs "${FIXTURES}/suppression_without_reason.rs.txt"
  run make --no-print-directory static-analysis
  assert_failure
  assert_output --partial "\`expect\` attribute without specifying a reason"
  assert_output --partial 'allow_attributes_without_reason'
}

# bats test_tags=slow
@test "G2: static-analysis rejects a broken intra-doc link" {
  # The plant is used and documented, so both clippy passes accept it and rustdoc is the pass that fails.
  plant_append xtask/src/main.rs "${FIXTURES}/broken_doc_link.rs.txt"
  run make --no-print-directory static-analysis
  assert_failure
  assert_output --partial "unresolved link to \`NoSuchPlantedItem\`"
  assert_output --partial 'rustdoc::broken-intra-doc-links'
}

# bats test_tags=slow
@test "G3: complexity rejects a function with six parameters" {
  plant_append xtask/src/main.rs "${FIXTURES}/too_many_arguments.rs.txt"
  run make --no-print-directory complexity
  assert_failure
  assert_output --partial 'too many arguments (6/5)'
}

# The recipe that make echoes names every lint of G3, so these tests assert clippy's own message instead.

# bats test_tags=slow
@test "G3: complexity rejects a function over the line limit" {
  plant_append xtask/src/main.rs "${FIXTURES}/too_many_lines.rs.txt"
  run make --no-print-directory complexity
  assert_failure
  assert_output --partial 'this function has too many lines (57/50)'
}

# bats test_tags=slow
@test "G3: complexity rejects a function nested six levels deep" {
  plant_append xtask/src/main.rs "${FIXTURES}/excessive_nesting.rs.txt"
  run make --no-print-directory complexity
  assert_failure
  assert_output --partial 'this block is too nested'
}

# bats test_tags=slow
@test "G3: complexity rejects a function over the cognitive-complexity limit" {
  plant_append xtask/src/main.rs "${FIXTURES}/cognitive_complexity.rs.txt"
  run make --no-print-directory complexity
  assert_failure
  assert_output --partial 'the function has a cognitive complexity of (11/8)'
}

@test "G4: architecture reports the violations of the checker's fixture workspace" {
  run make --no-print-directory architecture \
    ARCH_ARGS='--config xtask/tests/fixtures/arch/valid.toml --manifest-path xtask/tests/fixtures/arch/workspace/Cargo.toml'
  assert_failure
  assert_output --partial 'arch::layer'
  assert_output --partial '] Error 1'
}

# --- G5, G6, G8: manifest, configuration, unused dependencies ----------------------------------------------

@test "G5: validate-manifest fails when the workspace version changes without a lock update" {
  sed '/^\[workspace\.package\]/,/^\[/ s/^version = ".*"$/version = "99.0.0"/' Cargo.toml >"${tmp}/Cargo.toml"
  run ! cmp -s "${tmp}/Cargo.toml" Cargo.toml
  plant_replace Cargo.toml "${tmp}/Cargo.toml"
  run make --no-print-directory validate-manifest
  assert_failure
  # cargo's own message: the echoed recipe line also contains `--locked`, so it must not decide the test. The path
  # of the lock file may contain a space (a checkout path on a developer machine).
  assert_output --regexp 'cannot update the lock file .*Cargo\.lock because --locked was passed'
}

@test "G6: check-requirements fails with status 2 and names DATABASE_URL" {
  require_host_mode "the DATABASE_URL set here does not reach the container"
  run env DATABASE_URL=mysql://x scripts/with-env.sh .env -- make --no-print-directory check-requirements
  assert_failure 2
  assert_output --partial 'DATABASE_URL'
  # Make's error line carries the status of the recipe, which is the status of the command itself.
  assert_output --partial '] Error 2'
}

@test "G8: unused-dependencies names an unused dependency and leaves Cargo.lock as it found it" {
  require_command cargo
  sed 's/^\[dependencies\]$/&\nhumantime.workspace = true/' xtask/Cargo.toml >"${tmp}/Cargo.toml"
  run ! cmp -s "${tmp}/Cargo.toml" xtask/Cargo.toml
  plant_keep Cargo.lock
  plant_replace xtask/Cargo.toml "${tmp}/Cargo.toml"
  run cargo update --workspace --offline
  assert_success
  local lock_before
  lock_before="$(cksum <Cargo.lock)"
  run make --no-print-directory unused-dependencies
  assert_failure
  assert_output --partial 'humantime'
  assert_equal "$(cksum <Cargo.lock)" "${lock_before}"
}

# --- G7: one negative test per policy of cargo-deny --------------------------------------------------------

@test "G7: check-security rejects every licence when the allow-list is empty" {
  # The fixture is a copy of deny.toml with one policy changed: fail when deny.toml was edited since.
  sed '/^\[licenses\]/,/^\[/ { /^allow = \[$/,/^\]$/c\
allow = []
}' deny.toml | diff - "${FIXTURES}/deny_no_licences.toml.txt"
  plant_replace deny.toml "${FIXTURES}/deny_no_licences.toml.txt"
  run make --no-print-directory check-security
  assert_failure
  assert_output --partial 'license is not explicitly allowed'
}

@test "G7: check-security rejects every registry when allow-registry is empty" {
  # The fixture is a copy of deny.toml with one policy changed: fail when deny.toml was edited since.
  sed '/^allow-registry = /s/=.*/= []/' deny.toml | diff - "${FIXTURES}/deny_no_registries.toml.txt"
  plant_replace deny.toml "${FIXTURES}/deny_no_registries.toml.txt"
  run make --no-print-directory check-security
  assert_failure
  assert_output --partial 'source-not-allowed'
}

@test "G7: check-security reports a published advisory of a locked dependency" {
  require_command cargo
  # The vulnerable project is generated here and never stored: smallvec 1.6.0 has RUSTSEC-2021-0003.
  mkdir -p "${tmp}/project/src"
  : >"${tmp}/project/src/lib.rs"
  cat >"${tmp}/project/Cargo.toml" <<'EOF'
[package]
name = "vulnerable-fixture"
version = "0.0.0"
edition = "2021"
publish = false

[dependencies]
smallvec = "=1.6.0"
EOF
  run cargo generate-lockfile --manifest-path "${tmp}/project/Cargo.toml"
  assert_success
  run make --no-print-directory check-security \
    DENY_ARGS="--manifest-path ${tmp}/project/Cargo.toml --config ${REPO_ROOT}/deny.toml"
  assert_failure
  assert_output --partial 'error[vulnerability]'
  assert_output --partial 'RUSTSEC-2021-0003'
}

# --- G29: crate isolation ----------------------------------------------------------------------------------

# bats test_tags=slow
@test "G29: check-crate-isolation fails on xtask although cargo check --workspace passes" {
  require_command cargo
  plant_append xtask/src/main.rs "${FIXTURES}/isolation_violation.rs.txt"
  run cargo check --locked --workspace
  assert_success
  run make --no-print-directory check-crate-isolation
  assert_failure
  assert_output --partial 'xtask'
  assert_output --partial 'RawValue'
}

# --- G25: protected configuration --------------------------------------------------------------------------

@test "G25: validate-configuration rejects a modified protected file" {
  printf '# planted by a test\n' >"${tmp}/comment.txt"
  plant_append clippy.toml "${tmp}/comment.txt"
  run env -u CONFIG_CHANGE_APPROVED make --no-print-directory validate-configuration base_ref=HEAD
  assert_failure
  assert_output --partial 'Modification of locked configuration file is not allowed: clippy.toml'
  assert_output --partial '[FAIL]'
  assert_output --partial 'Approve with the label approved-config-change'
}

@test "G25: validate-configuration exits 2 for a base ref that does not exist" {
  run env -u CONFIG_CHANGE_APPROVED make --no-print-directory validate-configuration base_ref=no-such-ref
  assert_failure 2
  assert_output --partial 'base ref no-such-ref is not available'
  assert_output --partial '] Error 2'
}

# --- the harness itself ------------------------------------------------------------------------------------

@test "a plant that an interrupted run left behind is repaired by the next setup" {
  local before
  before="$(cksum <xtask/src/main.rs)"
  plant_append xtask/src/main.rs "${FIXTURES}/unwrap_used.rs.txt"
  [[ "$(cksum <xtask/src/main.rs)" != "${before}" ]]
  _common_setup
  assert_equal "$(cksum <xtask/src/main.rs)" "${before}"
  assert_equal "$(tree_status)" "${tree_before}"
}
