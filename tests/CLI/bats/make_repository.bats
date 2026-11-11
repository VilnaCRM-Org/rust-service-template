#!/usr/bin/env bats
# Negative tests of the repository gates: one test per linter of G23 (lint-repo), and the Make-level tests of the
# documentation-drift gate G26, the architecture-model gate G27 and the invariants gate G31. There is no passing-run
# test of a gate: the passing run of lint-repo is the gate itself (DD-02, DD-07). The template-sync check of the
# synchronised Rust files has no Make target, so its passing run is a test here, next to its negative
# (architecture-delivery.md "CLI Tests (Bats)", file make_repository.bats).
#
# A violation is planted under a name that the linter picks up (the fixtures keep the extension .txt and are excluded
# from every linter) and is removed by restore_planted, which the teardown calls.

bats_require_minimum_version 1.8.0
load test_helper

# bats file_tags=repository

setup() {
  _common_setup
  fixtures="${REPO_ROOT}/tests/CLI/bats/fixtures"
  tmp="$(mktemp -d)"
  # The misspelt word is assembled so that this file itself passes the spelling check.
  misspelt="reci""eve"
}

teardown() {
  restore_planted
  [[ -z "${tmp:-}" ]] || rm -rf -- "${tmp}"
}

# --- G23: one test per linter -------------------------------------------------------------------------------

@test "lint-actions: a workflow with a syntax error fails with the finding of actionlint" {
  require_docker
  plant_new .github/workflows/planted_syntax_error.yml "${fixtures}/workflow_syntax_error.yml.txt"
  run make --no-print-directory lint-actions
  assert_failure
  assert_output --partial 'planted_syntax_error.yml'
  assert_output --regexp '\[(syntax-check|shell-name|expression)\]'
}

@test "lint-actions: a workflow with an unpinned action fails with the finding of zizmor" {
  require_docker
  require_command zizmor
  plant_new .github/workflows/planted_unpinned_action.yml "${fixtures}/workflow_unpinned_action.yml.txt"
  run make --no-print-directory lint-actions
  assert_failure
  assert_output --partial 'unpinned-uses'
  assert_output --partial 'planted_unpinned_action.yml'
}

@test "lint-yaml: a YAML file with a duplicate key fails with the finding of yamllint" {
  require_docker
  plant_new planted_duplicate_key.yml "${fixtures}/duplicate_key.yml.txt"
  run make --no-print-directory lint-yaml
  assert_failure
  assert_output --partial 'planted_duplicate_key.yml'
  assert_output --partial 'duplication of key'
}

@test "lint-markdown: a Markdown file with a skipped heading level fails with the finding of markdownlint" {
  require_docker
  plant_new planted_skipped_heading.md "${fixtures}/skipped_heading.md.txt"
  run make --no-print-directory lint-markdown
  assert_failure
  assert_output --partial 'planted_skipped_heading.md'
  assert_output --partial 'MD001'
}

@test "lint-shell: a script with an unquoted expansion fails with the finding of shellcheck" {
  require_docker
  plant_new scripts/planted_unquoted_expansion.sh "${fixtures}/unquoted_expansion.sh.txt"
  run make --no-print-directory lint-shell
  assert_failure
  assert_output --partial 'planted_unquoted_expansion.sh'
  assert_output --partial 'SC2086'
}

@test "lint-docker: a Dockerfile with the tag latest fails with the finding of hadolint" {
  require_docker
  run make --no-print-directory lint-docker DOCKERFILES=tests/CLI/bats/fixtures/Dockerfile.latest.txt
  assert_failure
  assert_output --partial 'DL3007'
}

@test "lint-toml: an unformatted TOML file fails with the finding of taplo" {
  require_command taplo
  plant_new planted_unformatted.toml "${fixtures}/unformatted.toml.txt"
  run make --no-print-directory lint-toml
  assert_failure
  assert_output --regexp 'not properly formatted path="[^"]*/planted_unformatted\.toml"'
}

@test "lint-spelling: a misspelt word fails with the finding of typos" {
  require_command typos
  plant_new planted_misspelt.md "${fixtures}/misspelt.md.txt"
  run make --no-print-directory lint-spelling
  assert_failure
  assert_output --partial "${misspelt}"
  assert_output --partial 'planted_misspelt.md'
}

@test "lint-spelling: a misspelt file name fails with the finding of typos" {
  require_command typos
  plant_new "planted_${misspelt}_name.md" "${fixtures}/skipped_heading.md.txt"
  run make --no-print-directory lint-spelling
  assert_failure
  assert_output --partial "${misspelt}"
  assert_output --partial "planted_${misspelt}_name.md"
}

@test "lint-spelling: a misspelt workflow name fails with the finding of typos" {
  require_command typos
  printf 'name: Planted %s\non: push\n' "${misspelt}" >"${tmp}/workflow.yml"
  plant_new .github/workflows/planted_spelling.yml "${tmp}/workflow.yml"
  run make --no-print-directory lint-spelling
  assert_failure
  assert_output --partial "${misspelt}"
  assert_output --partial '.github/workflows/planted_spelling.yml'
}

@test "lint-spelling: a misspelt file name in a hidden directory fails with the finding of typos" {
  require_command typos
  plant_new ".github/planted_${misspelt}_name.md" "${fixtures}/skipped_heading.md.txt"
  run make --no-print-directory lint-spelling
  assert_failure
  assert_output --partial "${misspelt}"
  assert_output --partial ".github/planted_${misspelt}_name.md"
}

@test "lint-prettier: an unformatted JSON file fails with the finding of Prettier" {
  require_docker
  plant_new planted_unformatted.json "${fixtures}/unformatted.json.txt"
  run make --no-print-directory lint-prettier
  assert_failure
  assert_output --partial 'planted_unformatted.json'
  assert_output --partial 'Code style issues found'
}

# --- Template sync: synchronised tests stay free of the example context -------------------------------------

# The Rust files a commit would contain (tracked, or untracked and not ignored by git) that name the example
# context or build the `Adapters` literal and that the template sync does not ignore. A sync restores the
# template's copy of such a file, so it must not depend on what a service changes (FR100).
synchronised_rust_files_naming_the_example() {
  local -a naming=()
  mapfile -t naming < <(git ls-files -z --cached --others --exclude-standard -- '*.rs' |
    xargs -0 grep -l -s -E 'example_api_resources|ExampleApiResource|some_module|Adapters \{' -- | sort -u)
  ((${#naming[@]} > 0)) || return 0
  comm -23 <(printf '%s\n' "${naming[@]}") \
    <(git ls-files --cached --others --ignored --exclude-from=.templatesyncignore -- "${naming[@]}" | sort -u)
}

@test "no synchronised Rust file names the example context or builds the Adapters literal" {
  run synchronised_rust_files_naming_the_example
  assert_success
  assert_output ''
}

@test "a planted synchronised test that names the example table is reported" {
  printf 'const TABLE: &str = "example_api_resources";\n' >"${tmp}/planted.rs"
  plant_new crates/shared/infrastructure/tests/integration/planted_example_table.rs "${tmp}/planted.rs"
  run synchronised_rust_files_naming_the_example
  assert_success
  assert_output 'crates/shared/infrastructure/tests/integration/planted_example_table.rs'
}

# --- G26, G27, G31 ------------------------------------------------------------------------------------------

# bats test_tags=slow
@test "docs-check: a command that is no Make target fails with a rule (1) line" {
  printf 'Run \x60make no-such-target\x60 to see it fail.\n' >"${tmp}/line"
  plant_append README.md "${tmp}/line"
  run make --no-print-directory docs-check
  assert_failure
  assert_output --regexp '\(1\) README\.md:[0-9]+: .*no-such-target'
}

@test "validate-architecture-model: a line that does not parse fails with the error of the parser" {
  require_docker
  plant_append workspace.dsl "${fixtures}/broken_relationship.dsl.txt"
  run make --no-print-directory validate-architecture-model
  assert_failure
  assert_output --regexp 'Unexpected tokens at line [0-9]+ of /work/workspace\.dsl: planted -> nowhere'
  assert_output --partial 'does not parse'
}

@test "validate-invariants: another toolchain version fails with a rule (c) line" {
  sed -E 's/^(channel[[:space:]]*=[[:space:]]*)"[^"]*"/\1"1.0.0"/' rust-toolchain.toml >"${tmp}/toolchain"
  plant_replace rust-toolchain.toml "${tmp}/toolchain"
  run make --no-print-directory validate-invariants
  assert_failure
  assert_output --regexp '\(c\) .*toolchain versions differ'
}
