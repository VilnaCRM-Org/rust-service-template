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

@test "make -n ci runs exactly the gates of make ci-list, in the same order" {
  local planned listed
  run make --no-print-directory ci-list
  assert_success
  listed="${output}"
  run make -n ci
  assert_success
  # The recipe of every stage has one line per gate; the stage targets themselves are reached through the loop of `ci`.
  planned="$(awk '/^make --no-print-directory [a-z0-9-]+$/ && $3 != "doctor" {print $3}' <<<"${output}")"
  [[ -n "${planned}" ]]
  assert_equal "${planned}" "${listed}"
}

@test "a gate added to a stage variable is run by that stage and one removed from it is not" {
  printf 'CI_CLI_TARGETS := bats added-gate\nCI_PREFLIGHT_TARGETS := lint-repo\n' >"${tmp}/stages.mk"
  run make -n -f Makefile -f "${tmp}/stages.mk" ci-cli
  assert_success
  assert_output --partial 'make --no-print-directory added-gate'
  run make -n -f Makefile -f "${tmp}/stages.mk" ci-preflight
  assert_success
  assert_output 'make --no-print-directory lint-repo'
}

@test "a failing gate stops its stage before the next gate" {
  # The nested makes of a stage do not see a second -f file, so the gates live in the service fragment of a copy.
  mkdir -p "${tmp}/make"
  cp Makefile "${tmp}/"
  cp make/gates.mk make/tool-versions.mk "${tmp}/make/"
  printf 'CI_CLI_TARGETS := first second\nfirst:\n\t@echo first-ran; exit 1\nsecond:\n\t@echo second-ran\n' >"${tmp}/make/service.mk"
  run make -C "${tmp}" --no-print-directory ci-cli
  assert_failure
  assert_output --partial 'first-ran'
  refute_output --partial 'second-ran'
  # The same stage with a passing first gate runs both.
  printf 'CI_CLI_TARGETS := first second\nfirst:\n\t@echo first-ran\nsecond:\n\t@echo second-ran\n' >"${tmp}/make/service.mk"
  run make -C "${tmp}" --no-print-directory ci-cli
  assert_success
  assert_output --partial 'second-ran'
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

@test "scripts/doctor.sh checks the make named by MAKE_COMMAND, not the one on PATH" {
  mkdir -p "${tmp}/bin"
  printf '#!/bin/sh\necho "GNU Make 3.81"\n' >"${tmp}/bin/make"
  printf '#!/bin/sh\necho "GNU Make 3.81"\n' >"${tmp}/bin/oldmake"
  printf '#!/bin/sh\necho "GNU Make 4.3"\n' >"${tmp}/bin/gmake"
  chmod +x "${tmp}/bin/make" "${tmp}/bin/oldmake" "${tmp}/bin/gmake"
  # An old `make` first on PATH, the GNU Make that runs the doctor named by the Makefile: the doctor accepts it.
  PATH="${tmp}/bin:${PATH}" MAKE_COMMAND="${tmp}/bin/gmake" run scripts/doctor.sh
  assert_success
  assert_line '[OK] make 4.3'
  # The same old make named explicitly is reported, with the macOS hint.
  MAKE_COMMAND="${tmp}/bin/oldmake" run scripts/doctor.sh
  assert_failure 1
  assert_line --partial '[OUTDATED] make: found 3.81, need 4.0'
  # Without the variable the make on PATH is checked.
  PATH="${tmp}/bin:${PATH}" run scripts/doctor.sh
  assert_failure 1
  assert_line --partial '[OUTDATED] make: found 3.81, need 4.0'
  MAKE_COMMAND="${tmp}/bin/missing" run scripts/doctor.sh
  assert_failure 1
  assert_line --partial '[MISSING] make: needed by every target; install GNU Make 4.0 or newer (on macOS: brew install make'
  assert_line --partial 'libexec/gnubin first on PATH)'
}

@test "the doctor and bootstrap recipes hand the running make to the doctor, and a dry run does not run it" {
  run make -n doctor
  assert_success
  assert_output 'MAKE_COMMAND="make" scripts/doctor.sh'
  run make -n bootstrap RUN_IN_CONTAINER=1
  assert_success
  assert_line 'MAKE_COMMAND="make" scripts/doctor.sh --prerequisites'
  assert_line 'MAKE_COMMAND="make" scripts/doctor.sh'
  refute_output --partial '[OK]'
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

# --- scripts/with-env.sh ---------------------------------------------------------------------------------------------

# The names of tests/CLI/bats/fixtures/shared_env_forms.env.txt, in file order: the forms that the service (dotenvy),
# Docker Compose and with-env.sh must read the same way.
SHARED_FORMS=(PLAIN DOUBLE SINGLE COMMENTED HASH ESCAPES REFERENCES EMPTY)

@test "with-env.sh strips quotes and inline comments like the service and Compose do" {
  run scripts/with-env.sh "${BATS_TEST_DIRNAME}/fixtures/shared_env_forms.env.txt" -- printenv "${SHARED_FORMS[@]}"
  assert_success
  assert_equal "${output}" "$(cat "${BATS_TEST_DIRNAME}/fixtures/shared_env_forms.expected.txt")"
}

@test "with-env.sh reads the shared forms to the values Docker Compose reads" {
  require_command docker
  require_command jq
  local name expected
  printf '%s\n' 'services:' '  probe:' '    image: scratch' '    environment:' >"${tmp}/compose.yml"
  for name in "${SHARED_FORMS[@]}"; do
    printf '      %s: "%s"\n' "${name}" "\${${name}}" >>"${tmp}/compose.yml"
  done
  run docker compose -f "${tmp}/compose.yml" --env-file "${BATS_TEST_DIRNAME}/fixtures/shared_env_forms.env.txt" config --format json
  assert_success
  # Compose prints a literal dollar sign as two.
  expected="$(jq -r --argjson names "$(printf '%s\n' "${SHARED_FORMS[@]}" | jq -R . | jq -s .)" \
    '.services.probe.environment as $e | $names[] | $e[.] | gsub("[$][$]"; "$")' <<<"${output}")"
  assert_equal "${expected}" "$(cat "${BATS_TEST_DIRNAME}/fixtures/shared_env_forms.expected.txt")"
}

@test "with-env.sh never changes a variable of the caller, quoted or not" {
  printf '%s\n' 'KEPT="from the file"' 'OTHER=file' >"${tmp}/caller.env"
  KEPT=caller run scripts/with-env.sh "${tmp}/caller.env" -- printenv KEPT OTHER
  assert_success
  assert_output "caller"$'\n'"file"
}

@test "with-env.sh refuses the forms that dotenvy and Compose read differently, with status 2 and the line" {
  local line
  while IFS= read -r line; do
    printf '%s\n' "${line}" >"${tmp}/bad.env"
    run scripts/with-env.sh "${tmp}/bad.env" -- true
    assert_failure 2
    assert_output --partial "with-env.sh: invalid"
    assert_output --partial "${line}"
  done <"${BATS_TEST_DIRNAME}/fixtures/refused_env_lines.txt"
}

# --- G16: the negative test of the Bats gate ------------------------------------------------------------------------

@test "G16: make bats fails on a copy of the failing fixture suite" {
  require_docker
  cp tests/CLI/bats/fixtures/failing_suite/failing.bats.txt "${tmp}/failing.bats"
  # BATS_ARGS needs no explicit empty value: _common_setup removes the variables of the outer `make bats` call.
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

@test "restore_planted keeps the mode of a restored file and gives it a new modification time" {
  printf '# planted\n' >"${tmp}/fixture.txt"
  assert_file_executable scripts/doctor.sh
  plant_replace scripts/doctor.sh "${tmp}/fixture.txt"
  chmod 644 scripts/doctor.sh
  touch -t 200001010000 scripts/doctor.sh "$(_restore_dir)/files/0"
  touch "${tmp}/marker"
  sleep 1
  restore_planted
  assert_file_executable scripts/doctor.sh
  run git status --porcelain -- scripts/doctor.sh
  assert_output ''
  run find scripts/doctor.sh -newer "${tmp}/marker"
  assert_output 'scripts/doctor.sh'
}

@test "restore_planted removes a planted tree and unstages a planted index entry" {
  printf '\n# planted\n' >"${tmp}/fixture.txt"
  plant_tree crates/bats-tree-probe
  mkdir -p crates/bats-tree-probe/nested
  : >crates/bats-tree-probe/nested/file
  plant_append clippy.toml "${tmp}/fixture.txt"
  plant_index clippy.toml
  git add -- clippy.toml
  run git diff --cached --name-only -- clippy.toml
  assert_output 'clippy.toml'
  # The next test of an interrupted run starts with _common_setup, which repairs the tree and the index.
  _common_setup
  assert_dir_not_exists crates/bats-tree-probe
  run git diff --cached --name-only -- clippy.toml
  assert_output ''
  run git status --porcelain -- clippy.toml crates/bats-tree-probe
  assert_output ''
}

@test "plant_tree leaves a directory that existed before the plant alone" {
  plant_tree crates
  assert_file_not_exists target/bats-restore/manifest
  assert_dir_exists crates
}

@test "outer make variables do not reach the nested makes of the tests, the settings of the caller do" {
  # The probe prints what a nested make sees. `make bats X=y` exports X and also puts it into MAKEFLAGS, which
  # is how the hosted job and a developer start the suite; the same pair is built here by hand.
  cat >"${tmp}/probe.mk" <<'PROBE'
.RECIPEPREFIX = >
probe:
> @printf 'outer: BATS_ARGS=[%s] BATS_PATH=[%s] CI_STAGES=[%s] DEPS=[%s] base_ref=[%s]\n' "$(BATS_ARGS)" "$(BATS_PATH)" "$(CI_STAGES)" "$(DEPS)" "$(base_ref)"
> @printf 'kept: BUILD_IMAGE=[%s] DOCKER=[%s] DOCKER_COMPOSE=[%s] APP_IMAGE=[%s] DEV_IMAGE=[%s] LOAD_TEST_PROJECT=[%s]\n' "$(BUILD_IMAGE)" "$(DOCKER)" "$(DOCKER_COMPOSE)" "$(APP_IMAGE)" "$(DEV_IMAGE)" "$(LOAD_TEST_PROJECT)"
> @printf 'kept: COMPOSE_PROJECT_NAME=[%s] RUN_IN_CONTAINER=[%s] DB_PORT=[%s] LOCALSTACK_PORT=[%s]\n' "$(COMPOSE_PROJECT_NAME)" "$(RUN_IN_CONTAINER)" "$$DB_PORT" "$$LOCALSTACK_PORT"
> @printf 'flags: [%s] level=[%s]\n' "$(findstring CI_STAGES,$(MAKEFLAGS))" "$(MAKELEVEL)"
PROBE
  run env MAKEFLAGS=' -- BATS_ARGS=--filter-tags=none CI_STAGES=help BUILD_IMAGE=0' MAKELEVEL=1 \
    BATS_ARGS=--filter-tags=none BATS_PATH=/nonexistent CI_STAGES=help DEPS=x base_ref=nowhere \
    BUILD_IMAGE=0 DOCKER=/nonexistent/docker DOCKER_COMPOSE='nonexistent compose' APP_IMAGE=a:b DEV_IMAGE=c:d \
    LOAD_TEST_PROJECT=lp COMPOSE_PROJECT_NAME=cpn DB_PORT=1111 LOCALSTACK_PORT=2222 RUN_IN_CONTAINER=1 \
    bash -c "source tests/CLI/bats/test_helper.bash && isolate_make_environment && make --no-print-directory -f Makefile -f \"\$1\" probe" \
    _ "${tmp}/probe.mk"
  assert_success
  assert_line 'outer: BATS_ARGS=[] BATS_PATH=[tests/CLI/bats] CI_STAGES=[ci-preflight ci-static-analysis ci-tests ci-contracts ci-mutation ci-delivery ci-cli] DEPS=[database localstack] base_ref=[origin/main]'
  assert_line 'kept: BUILD_IMAGE=[0] DOCKER=[/nonexistent/docker] DOCKER_COMPOSE=[nonexistent compose] APP_IMAGE=[a:b] DEV_IMAGE=[c:d] LOAD_TEST_PROJECT=[lp]'
  assert_line 'kept: COMPOSE_PROJECT_NAME=[cpn] RUN_IN_CONTAINER=[1] DB_PORT=[1111] LOCALSTACK_PORT=[2222]'
  assert_line 'flags: [] level=[0]'
}

@test "the permission policy of the assistant denies every spelling that skips the git hooks" {
  require_command jq
  local entry
  for entry in 'Bash(git commit --no-verify:*)' 'Bash(git commit -n:*)' 'Bash(git push --no-verify:*)' \
    'Bash(git -c core.hooksPath:*)' 'Bash(git config core.hooksPath:*)' 'Bash(git push --force:*)' 'Bash(git push -f:*)'; do
    run jq -e --arg entry "${entry}" '.permissions.deny | index($entry) != null' .claude/settings.json
    assert_success
  done
  # A denied spelling must not also be allowed or only asked about.
  run jq -r '[.permissions.allow[], .permissions.ask[]] | map(select(test("^Bash\\(git (commit|push|-c|config)"))) | .[]' .claude/settings.json
  assert_output ''
}

@test "require_command skips with a reason" {
  run bash -c 'source tests/CLI/bats/test_helper.bash; skip() { echo "skipped: $*"; return 0; }; require_command no-such-command-anywhere'
  assert_output 'skipped: the command '"'"'no-such-command-anywhere'"'"' is required'
  run bash -c 'source tests/CLI/bats/test_helper.bash; skip() { echo "skipped: $*"; return 0; }; DOCKER=/nonexistent require_docker'
  assert_output 'skipped: a reachable container engine (docker) is required'
}
