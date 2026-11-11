#!/usr/bin/env bats
# Tests of the execution switch RUN_IN_CONTAINER and of the environment inside the development container
# (architecture-delivery.md DD-01 and "CLI Tests (Bats)", file make_execution_mode.bats).
#
# The tests that run a command in the container need the development environment. The file starts its own
# compose project, with a name and host ports of its own, and removes it with its volumes at the end, so it
# cannot collide with the stack of a developer (NFR38). The Makefile derives every name from PROJECT_NAME, so
# exporting it (and no COMPOSE_PROJECT_NAME) is all that addresses the private project.

bats_require_minimum_version 1.8.0
load test_helper

# bats file_tags=surface

# A free TCP port on the loopback interface that is not in the list of ports already chosen.
_free_port() {
  local port
  while :; do
    port=$((20000 + RANDOM % 20000))
    case " ${CHOSEN_PORTS:-} " in *" ${port} "*) continue ;; esac
    if ! (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null; then
      CHOSEN_PORTS="${CHOSEN_PORTS:-} ${port}"
      printf '%s' "${port}"
      return 0
    fi
  done
}

# Name of the development image that the Makefile derives from the checkout directory.
_default_dev_image() {
  printf '%s-app:dev' "$(basename "${REPO_ROOT}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_\n-' '-')"
}

# Removes the private project with its volumes (and, when the file built it, its image).
_remove_project() {
  [[ "${PROJECT_NAME:-}" == bats-* ]] || return 0
  docker compose --profile '*' -p "${PROJECT_NAME}" down --volumes --remove-orphans >/dev/null 2>&1 || true
  if [[ -n "${BUILT_IMAGE:-}" ]]; then
    docker image rm "${PROJECT_NAME}-app:dev" >/dev/null 2>&1 || true
  fi
}

setup_file() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  cd "${REPO_ROOT}" || return 1
  "${DOCKER:-docker}" info >/dev/null 2>&1 || return 0
  local suffix="${BASHPID}-${RANDOM}"
  isolate_make_environment
  unset COMPOSE_PROJECT_NAME CI IN_DEV_CONTAINER RUN_IN_CONTAINER
  export PROJECT_NAME="bats-exec-${suffix}"
  CHOSEN_PORTS=''
  DB_PORT="$(_free_port)"
  LOCALSTACK_PORT="$(_free_port)"
  APP_PORT="$(_free_port)"
  STRUCTURIZR_PORT="$(_free_port)"
  export DB_PORT LOCALSTACK_PORT APP_PORT STRUCTURIZR_PORT
  # An image that an earlier `make start` of this checkout built is reused; otherwise `make start` builds it.
  if [[ -z "${DEV_IMAGE:-}" ]]; then
    if docker image inspect "$(_default_dev_image)" >/dev/null 2>&1; then
      DEV_IMAGE="$(_default_dev_image)"
      export DEV_IMAGE
      export BUILD_IMAGE="${BUILD_IMAGE:-0}"
    else
      BUILT_IMAGE=1
      export BUILT_IMAGE
    fi
  fi
  # Nothing may be started unless the Makefile addresses the private project, which holds nothing yet.
  local addressed probe
  probe="$(mktemp)"
  printf "show:\n\t@echo \$\$COMPOSE_PROJECT_NAME\n" >"${probe}"
  addressed="$(make --no-print-directory -f Makefile -f "${probe}" show)"
  rm -f -- "${probe}"
  if [[ "${addressed}" != "${PROJECT_NAME}" || -n "$(docker compose -p "${PROJECT_NAME}" ps --all --quiet)" ]]; then
    echo "make addresses '${addressed}', not the empty private project '${PROJECT_NAME}'" >&2
    return 1
  fi
  make --no-print-directory start >&3 2>&3
}

teardown_file() {
  cd "${REPO_ROOT}" || return 0
  _remove_project
}

setup() {
  _common_setup
  require_docker
  tmp="$(mktemp -d)"
  # Every test addresses the private project or none at all.
  [[ "${PROJECT_NAME:-}" == bats-* ]] || fail "PROJECT_NAME is not a private project: '${PROJECT_NAME:-}'"
}

teardown() {
  restore_planted
  [[ -z "${tmp:-}" ]] || rm -rf -- "${tmp}"
}

# A makefile that runs a command behind $(EXEC) with the variables of the real Makefile.
probe_makefile() {
  printf "probe:\n\t@\$(EXEC) %s\n" "$1" >"${tmp}/probe.mk"
}

# --- the command line (no environment needed) ----------------------------------------------------------------

@test "make -n format-check runs natively" {
  run make --no-print-directory -n format-check
  assert_success
  assert_line --index 0 'cargo fmt --all --check'
  refute_output --partial 'docker compose exec'
}

@test "RUN_IN_CONTAINER=1 make -n format-check starts with docker compose exec -T and carries the five -e options" {
  RUN_IN_CONTAINER=1 run make --no-print-directory -n format-check
  assert_success
  assert_line --index 0 --regexp '^docker compose exec -T --user [0-9]+:[0-9]+ -e TEST_SEED -e PROPTEST_RNG_SEED -e CONFIG_CHANGE_APPROVED -e CARGO_BUILD_WARNINGS -e DATABASE_STATEMENT_TIMEOUT app cargo fmt --all --check$'
}

@test "RUN_IN_CONTAINER=true is the same opt-in" {
  RUN_IN_CONTAINER=true run make --no-print-directory -n format-check
  assert_success
  assert_line --index 0 --regexp '^docker compose exec -T '
}

@test "RUN_IN_CONTAINER=1 with CI=true is native again" {
  RUN_IN_CONTAINER=1 CI=true run make --no-print-directory -n format-check
  assert_success
  assert_line --index 0 'cargo fmt --all --check'
  refute_output --partial 'docker compose exec'
}

@test "RUN_IN_CONTAINER=1 with IN_DEV_CONTAINER=1 is native again" {
  RUN_IN_CONTAINER=1 IN_DEV_CONTAINER=1 run make --no-print-directory -n format-check
  assert_success
  assert_line --index 0 'cargo fmt --all --check'
  refute_output --partial 'docker compose exec'
}

@test "an orchestration target ignores the switch" {
  RUN_IN_CONTAINER=1 run make --no-print-directory -n lint-docker
  assert_success
  assert_output --partial 'hadolint'
  refute_output --partial 'docker compose exec'
  RUN_IN_CONTAINER=1 run make --no-print-directory -n start-deps
  assert_success
  assert_output --partial 'up --detach --wait --no-recreate database localstack'
  refute_output --partial 'compose exec'
}

# --- the targets in the running development container ----------------------------------------------------------

@test "RUN_IN_CONTAINER=1 make format-check succeeds in the running container" {
  RUN_IN_CONTAINER=1 run make --no-print-directory format-check
  assert_success
}

@test "RUN_IN_CONTAINER=1 make check-requirements succeeds in the running container" {
  RUN_IN_CONTAINER=1 run make --no-print-directory check-requirements
  assert_success
}

@test "RUN_IN_CONTAINER=1 make lint-rustdoc (the env form behind exec) succeeds in the running container" {
  RUN_IN_CONTAINER=1 run make --no-print-directory lint-rustdoc
  assert_success
}

@test "RUN_IN_CONTAINER=1 make setup-test-db succeeds in the running container" {
  RUN_IN_CONTAINER=1 run make --no-print-directory setup-test-db
  assert_success
}

@test "inside the container the test environment is APP_ENV=test and a URL on database:5432/app_test" {
  probe_makefile "\$(TEST_ENV) printenv APP_ENV DATABASE_URL"
  RUN_IN_CONTAINER=1 run make --no-print-directory -f Makefile -f "${tmp}/probe.mk" probe
  assert_success
  assert_line --index 0 'test'
  assert_line --index 1 --regexp '^postgres://[^@]+@database:5432/app_test$'
}

@test "TEST_SEED=7 reaches a command behind EXEC" {
  probe_makefile "bash -c 'echo \"seed=[\$\${TEST_SEED-unset}]\"'"
  RUN_IN_CONTAINER=1 TEST_SEED=7 run make --no-print-directory -f Makefile -f "${tmp}/probe.mk" probe
  assert_success
  assert_output 'seed=[7]'
}

@test "without TEST_SEED the variable is unset behind EXEC" {
  probe_makefile "bash -c 'echo \"seed=[\$\${TEST_SEED-unset}]\"'"
  RUN_IN_CONTAINER=1 run env -u TEST_SEED make --no-print-directory -f Makefile -f "${tmp}/probe.mk" probe
  assert_success
  assert_output 'seed=[unset]'
}

@test "DATABASE_STATEMENT_TIMEOUT=30m reaches a command behind EXEC" {
  probe_makefile "bash -c 'echo \"timeout=[\$\${DATABASE_STATEMENT_TIMEOUT-unset}]\"'"
  RUN_IN_CONTAINER=1 DATABASE_STATEMENT_TIMEOUT=30m run make --no-print-directory -f Makefile -f "${tmp}/probe.mk" probe
  assert_success
  assert_output 'timeout=[30m]'
}

@test "without DATABASE_STATEMENT_TIMEOUT the variable is unset behind EXEC" {
  probe_makefile "bash -c 'echo \"timeout=[\$\${DATABASE_STATEMENT_TIMEOUT-unset}]\"'"
  RUN_IN_CONTAINER=1 run env -u DATABASE_STATEMENT_TIMEOUT make --no-print-directory -f Makefile -f "${tmp}/probe.mk" probe
  assert_success
  assert_output 'timeout=[unset]'
}

@test "RUN_IN_CONTAINER=1 scripts/doctor.sh without cargo on PATH exits 0 and prints the SKIP line" {
  local tool path
  mkdir -p "${tmp}/bin"
  for tool in bash sed grep head sort uname tr dirname cat make git curl docker bats; do
    path="$(command -v "${tool}" || true)"
    [[ -z "${path}" ]] || ln -s "${path}" "${tmp}/bin/${tool}"
  done
  run env -i PATH="${tmp}/bin" HOME="${tmp}" RUN_IN_CONTAINER=1 "$(command -v bash)" scripts/doctor.sh
  assert_success
  assert_line '[SKIP] toolchain and cargo tools: provided by the development container'
  refute_output --partial '[MISSING] cargo'
}

# --- negative tests ------------------------------------------------------------------------------------------------

@test "an orchestration target without a reachable engine exits 2 and names the engine" {
  DOCKER=/nonexistent run make --no-print-directory lint-docker
  assert_failure 2
  assert_output --partial 'This target needs a reachable container engine'
}

# Last test of the file: it stops the environment.
@test "RUN_IN_CONTAINER=1 make format-check with the environment stopped fails with the service-is-not-running message" {
  run make --no-print-directory stop
  assert_success
  RUN_IN_CONTAINER=1 run make --no-print-directory format-check
  assert_failure
  assert_output --partial 'is not running'
}
