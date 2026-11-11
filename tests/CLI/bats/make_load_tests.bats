#!/usr/bin/env bats
# Tests of the load-test targets (architecture-delivery.md "CLI Tests (Bats)", file make_load_tests.bats): the
# single-scenario runner, the AWS dry run against LocalStack, and the negative tests of gates G22 and G24.
#
# The isolated production-image environment is started and removed by the targets under test; tests that start
# it must not run beside another run of it. Local budgets are written to the git-ignored tests/Load/config.json
# with the harness, so teardown removes them. Make reports every failed recipe with its own status 2.

bats_require_minimum_version 1.8.0
load test_helper

# bats file_tags=load

RESULTS_DIR=tests/Load/results

setup() {
  _common_setup
}

teardown() {
  restore_planted
  rm -f -- "${RESULTS_DIR}/health.html" "${RESULTS_DIR}/smoke-health.html"
  if [[ -f tests/Load/aws-run.env ]]; then
    make --no-print-directory aws-load-tests-cleanup LOCAL_MODE_ENV=true >/dev/null 2>&1 || true
  fi
}

# Value of a Make variable after the Makefile was read, so the tests follow the caller's environment.
make_var() {
  make --no-print-directory --silent -f Makefile -f - "print-$1" <<'MAKEFILE'
.RECIPEPREFIX = >
print-%:
> @printf '%s' "$($*)"
MAKEFILE
}

# Ids of the containers, volumes and networks that the isolated environment owns; empty when it is gone.
isolated_project_resources() {
  local filter
  filter="label=com.docker.compose.project=$(make_var LOAD_TEST_PROJECT)"
  docker ps --all --quiet --filter "${filter}"
  docker volume ls --quiet --filter "${filter}"
  docker network ls --quiet --filter "${filter}"
}

# Containers of the development project with their state, to compare before and after a run.
development_containers() {
  docker ps --all --filter "label=com.docker.compose.project=$(make_var PROJECT_NAME)" \
    --format '{{.ID}} {{.Names}} {{.State}}' | sort
}

# Plants a local tests/Load/config.json that is config.json.dist with the smoke budget of the health scenario.
plant_smoke_budget() {
  jq --argjson budget "$1" '.endpoints.health.smoke.threshold = $budget' tests/Load/config.json.dist \
    >"${BATS_TEST_TMPDIR}/config.json"
  plant_new tests/Load/config.json "${BATS_TEST_TMPDIR}/config.json"
}

# --- setup-load-test-db ----------------------------------------------------------------------------------------

@test "setup-load-test-db takes the role and the database from the container, not from DB_USER and DB_NAME of the shell" {
  mkdir -p "${BATS_TEST_TMPDIR}/bin"
  cat >"${BATS_TEST_TMPDIR}/bin/docker" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"${RECORD}"
case "$*" in *' ps '*) echo some-container-id ;; esac
exit 0
STUB
  chmod +x "${BATS_TEST_TMPDIR}/bin/docker"
  PATH="${BATS_TEST_TMPDIR}/bin:${PATH}" RECORD="${BATS_TEST_TMPDIR}/calls" LOAD_TEST_PROJECT=bats-other-load DB_USER=orders DB_NAME=orders \
    run scripts/setup-load-test-db.sh
  assert_success
  # The statements run in the database container and expand the variables of that container.
  local dollar='$'
  run grep -c -F "exec -T database sh -c dropdb -U \"${dollar}POSTGRES_USER\" --if-exists --force \"${dollar}POSTGRES_DB\"" "${BATS_TEST_TMPDIR}/calls"
  assert_output '1'
  run grep -c -F "exec -T database sh -c createdb -U \"${dollar}POSTGRES_USER\" \"${dollar}POSTGRES_DB\"" "${BATS_TEST_TMPDIR}/calls"
  assert_output '1'
  run grep -c -E 'orders|-U app' "${BATS_TEST_TMPDIR}/calls"
  assert_output '0'
}

@test "setup-load-test-db refuses the development project and does not call docker" {
  mkdir -p "${BATS_TEST_TMPDIR}/bin"
  printf '#!/bin/sh\necho called >>"%s/calls"\n' "${BATS_TEST_TMPDIR}" >"${BATS_TEST_TMPDIR}/bin/docker"
  chmod +x "${BATS_TEST_TMPDIR}/bin/docker"
  PATH="${BATS_TEST_TMPDIR}/bin:${PATH}" LOAD_TEST_PROJECT="$(make_var PROJECT_NAME)" run scripts/setup-load-test-db.sh
  assert_failure 2
  assert_output --partial 'refusing to act on project'
  assert_file_not_exists "${BATS_TEST_TMPDIR}/calls"
}

# --- execute-load-tests-script -------------------------------------------------------------------------------

# bats test_tags=slow
@test "execute-load-tests-script writes health.html, removes the isolated project and leaves the development containers unchanged" {
  require_docker
  rm -f -- "${RESULTS_DIR}/health.html"
  local before after
  before="$(development_containers)"
  run make --no-print-directory execute-load-tests-script scenario=health runAverage=false runStress=false runSpike=false
  assert_success
  assert_file_exists "${RESULTS_DIR}/health.html"
  run isolated_project_resources
  assert_success
  assert_output ''
  after="$(development_containers)"
  assert_equal "${after}" "${before}"
}

# --- aws-load-tests against LocalStack -------------------------------------------------------------------------

# bats test_tags=slow
@test "aws-load-tests with LOCAL_MODE_ENV=true prints the instance and bucket lines, and the cleanup succeeds" {
  require_docker
  run make --no-print-directory start-deps DEPS=localstack
  assert_success
  # The branch and the repository URL are given: a pull-request job checks out a detached HEAD, and a clone made
  # from a local path has no HTTPS origin, which the script refuses on purpose.
  run make --no-print-directory aws-load-tests LOCAL_MODE_ENV=true branch=load-dry-run repo_url=https://example.com/acme/service.git
  assert_success
  assert_output --partial 'Repository URL: https://example.com/acme/service.git'
  assert_output --partial 'Repository branch: load-dry-run'
  assert_output --partial 'Launched instance'
  assert_output --partial 'You can access the S3 bucket here'
  assert_file_exists tests/Load/aws-run.env
  run make --no-print-directory aws-load-tests-cleanup LOCAL_MODE_ENV=true
  assert_success
  assert_file_not_exists tests/Load/aws-run.env
}

@test "aws-load-tests refuses a detached HEAD without a branch and exits 2 before any container or AWS call" {
  require_command git
  # A throw-away clone with a detached HEAD: the checkout of the developer is never touched.
  git clone --quiet --local --no-hardlinks "${REPO_ROOT}" "${BATS_TEST_TMPDIR}/clone"
  git -C "${BATS_TEST_TMPDIR}/clone" remote set-url origin https://example.org/org/service.git
  git -C "${BATS_TEST_TMPDIR}/clone" checkout --quiet --detach
  run env LOCAL_MODE_ENV=true "${BATS_TEST_TMPDIR}/clone/tests/Load/aws-execute-load-tests.sh"
  assert_failure 2
  assert_output --partial 'Error: HEAD is detached; give the branch with -b (make aws-load-tests branch=<name>).'
  assert_file_not_exists "${BATS_TEST_TMPDIR}/clone/tests/Load/aws-run.env"
}

@test "aws-load-tests refuses a path origin without a repository URL and exits 2 before any container or AWS call" {
  require_command git
  # A throw-away clone whose origin is a local path (a mirror, or a clone made with --no-local).
  git clone --quiet --local --no-hardlinks "${REPO_ROOT}" "${BATS_TEST_TMPDIR}/clone"
  git -C "${BATS_TEST_TMPDIR}/clone" remote set-url origin "${BATS_TEST_TMPDIR}/mirror.git"
  run env LOCAL_MODE_ENV=true "${BATS_TEST_TMPDIR}/clone/tests/Load/aws-execute-load-tests.sh" -b load-dry-run
  assert_failure 2
  assert_output --partial "Error: the URL of the remote 'origin' cannot be converted to HTTPS; give the repository URL with -u (make aws-load-tests repo_url=<https url>)."
  assert_file_not_exists "${BATS_TEST_TMPDIR}/clone/tests/Load/aws-run.env"
}

@test "lint-prettier, lint-yaml and lint-toml pass with generated load-test files present" {
  require_docker
  printf '<html><body>   generated   dashboard</body></html>\n' >"${BATS_TEST_TMPDIR}/dashboard.html"
  printf '{   "apiHost":"localhost",\n"apiPort":"8081" }\n' >"${BATS_TEST_TMPDIR}/config.json"
  printf 'BUCKET=planted\nROLE=planted\n' >"${BATS_TEST_TMPDIR}/aws-run.env"
  plant_new "${RESULTS_DIR}/health.html" "${BATS_TEST_TMPDIR}/dashboard.html"
  plant_new "${RESULTS_DIR}/smoke-health.html" "${BATS_TEST_TMPDIR}/dashboard.html"
  plant_new tests/Load/config.json "${BATS_TEST_TMPDIR}/config.json"
  plant_new tests/Load/aws-run.env "${BATS_TEST_TMPDIR}/aws-run.env"
  run make --no-print-directory lint-prettier
  assert_success
  run make --no-print-directory lint-yaml
  assert_success
  run make --no-print-directory lint-toml
  assert_success
}

# --- G22: load budgets -----------------------------------------------------------------------------------------

# bats test_tags=slow
@test "G22: smoke-load-tests with a local budget of 0.001 fails the thresholds and still writes smoke-health.html" {
  require_docker
  rm -f -- "${RESULTS_DIR}/smoke-health.html"
  plant_smoke_budget 0.001
  run make --no-print-directory smoke-load-tests
  assert_failure
  assert_output --regexp 'thresholds on metrics .* have been crossed'
  assert_file_exists "${RESULTS_DIR}/smoke-health.html"
  run isolated_project_resources
  assert_success
  assert_output ''
}

@test "G22: a budget of -1 makes execute-load-test.sh print Invalid threshold value before any request" {
  require_docker
  plant_smoke_budget -1
  run tests/Load/execute-load-test.sh health
  assert_failure
  assert_output --partial 'Invalid threshold value'
  refute_output --partial 'http_reqs'
  assert_file_not_exists "${RESULTS_DIR}/health.html"
}

@test "G22: execute-load-tests-script without scenario fails with usage and starts nothing" {
  require_docker
  run make --no-print-directory execute-load-tests-script
  assert_failure
  assert_output --partial 'Usage: make execute-load-tests-script scenario=<name>'
  assert_output --partial '[runSmoke=false]'
  assert_output --partial 'each profile runs unless its variable is false'
  refute_output --partial 'runSmoke=true'
  assert_output --partial 'execute-load-tests-script] Error 2'
  run isolated_project_resources
  assert_success
  assert_output ''
}

# --- G24: load-test lint ---------------------------------------------------------------------------------------

@test "G24: a script with console.log and == makes lint-load-tests fail" {
  require_docker
  plant_new tests/Load/scripts/planted_lint.js "${BATS_TEST_DIRNAME}/fixtures/bad_load_script.js.txt"
  run make --no-print-directory lint-load-tests
  assert_failure
  assert_output --partial 'planted_lint.js'
  assert_output --partial 'no-console'
  assert_output --partial 'eqeqeq'
}

@test "G24: a prettier key in the package manifest of the load tests does not replace the root configuration" {
  require_docker
  jq '. + {prettier: {semi: false}}' tests/Load/package.json >"${BATS_TEST_TMPDIR}/package.json"
  plant_replace tests/Load/package.json "${BATS_TEST_TMPDIR}/package.json"
  run make --no-print-directory lint-load-tests
  assert_success
}
