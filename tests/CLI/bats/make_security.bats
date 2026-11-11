#!/usr/bin/env bats
# Tests of the security gates and of the hardening claims (architecture-delivery.md "CLI Tests (Bats)", file
# make_security.bats, DD-21, "Containers and Compose"): gates G9 and G10, the inspection of the production image
# and the inspection of the rendered production reference (NFR12).
#
# Passing runs of the two gates are not repeated (DD-02). The key pair of G9 is generated at test time and is
# never stored. The image under test is the production image of the environment (APP_IMAGE); it is built before
# the group runs, so these tests only read and run it.

bats_require_minimum_version 1.8.0
load test_helper

# bats file_tags=load

# Upper bound of the production image: 100 MiB.
IMAGE_SIZE_LIMIT=104857600

setup() {
  _common_setup
}

teardown() {
  restore_planted
  if [[ -n "${container:-}" ]]; then
    docker rm --force "${container}" >/dev/null 2>&1 || true
  fi
  rm -rf -- target/reports/image-scan
}

# Value of a Make variable after the Makefile was read, so the tests follow the caller's environment.
make_var() {
  make --no-print-directory --silent -f Makefile -f - "print-$1" <<'MAKEFILE'
.RECIPEPREFIX = >
print-%:
> @printf '%s' "$($*)"
MAKEFILE
}

# The production image of the environment; the test fails when it does not exist.
production_image() {
  local image
  image="$(make_var APP_IMAGE)"
  docker image inspect "${image}" >/dev/null 2>&1 || fail "the production image ${image} does not exist"
  printf '%s' "${image}"
}

# `docker compose config` of the production reference with the given variables set and no .env file read.
render_production_reference() {
  env -u DATABASE_URL -u AWS_REGION "$@" docker compose --env-file /dev/null \
    -f docker-compose.yml -f docker-compose.prod.yml config --format json
}

# --- G9: secrets scan --------------------------------------------------------------------------------------

@test "G9: a private key generated at test time in an untracked file makes secrets-scan report leaks found" {
  require_docker
  require_command openssl
  openssl genrsa -out "${BATS_TEST_TMPDIR}/key.pem" 2048 2>/dev/null
  plant_new planted_private_key.pem "${BATS_TEST_TMPDIR}/key.pem"
  run make --no-print-directory secrets-scan
  assert_failure
  assert_output --partial 'leaks found'
  assert_output --partial 'planted_private_key.pem:private-key'
}

# --- G10: image scan -----------------------------------------------------------------------------------------

# bats test_tags=slow
@test "G10: the vulnerable fixture image makes image-scan exit non-zero with a CRITICAL finding" {
  require_docker
  local fixture
  fixture="$(pinned_value VULNERABLE_FIXTURE_IMAGE)"
  [[ -n "${fixture}" ]] || fail "VULNERABLE_FIXTURE_IMAGE is not pinned in make/tool-versions.mk"
  docker image inspect "${fixture}" >/dev/null 2>&1 || docker pull --quiet "${fixture}" >/dev/null
  IMAGE_TO_SCAN="${fixture}" run make --no-print-directory image-scan
  assert_failure
  assert_output --partial 'CRITICAL'
}

# --- production image ------------------------------------------------------------------------------------------

@test "the production image runs as user 65532" {
  require_docker
  local image
  image="$(production_image)"
  run docker image inspect --format '{{.Config.User}}' "${image}"
  assert_success
  assert_output '65532:65532'
}

@test "the production image has no /bin/sh" {
  require_docker
  local image
  image="$(production_image)"
  run -127 docker run --rm --entrypoint /bin/sh "${image}" -c true
  assert_failure
  assert_output --partial '/bin/sh'
}

@test "the production image is at most 100 MiB" {
  require_docker
  local image size
  image="$(production_image)"
  size="$(docker image inspect --format '{{.Size}}' "${image}")"
  assert [ "${size}" -le "${IMAGE_SIZE_LIMIT}" ]
}

@test "the production image declares the healthcheck of the architecture" {
  require_docker
  local image
  image="$(production_image)"
  run docker image inspect --format '{{json .Config.Healthcheck}}' "${image}"
  assert_success
  run jq -e '.Test == ["CMD", "/app/service", "healthcheck"] and .Interval == 10000000000
    and .Timeout == 3000000000 and .Retries == 3 and .StartPeriod <= 30000000000' <<<"${output}"
  assert_success
}

@test "the production image becomes healthy through its own healthcheck with a read-only root and no capabilities" {
  require_docker
  local image status
  image="$(production_image)"
  # The liveness probe does not need the database or LocalStack: the connections are opened lazily.
  container="$(docker run --detach --read-only --cap-drop ALL --security-opt no-new-privileges:true \
    -e APP_ENV=prod -e DATABASE_URL=postgres://app:unused@127.0.0.1:1/app -e AWS_REGION=us-east-1 \
    -e AWS_ACCESS_KEY_ID=test -e AWS_SECRET_ACCESS_KEY=test -e AWS_ENDPOINT_URL_SQS=http://127.0.0.1:1 \
    "${image}")"
  run docker inspect --format '{{json .HostConfig}}' "${container}"
  assert_success
  run jq -e '.ReadonlyRootfs == true and .CapDrop == ["ALL"] and .CapAdd == null
    and (.SecurityOpt | index("no-new-privileges:true") != null)' <<<"${output}"
  assert_success
  status=''
  for _ in $(seq 1 40); do
    status="$(docker inspect --format '{{.State.Health.Status}}' "${container}")"
    [[ "${status}" == healthy || "${status}" == unhealthy ]] && break
    sleep 2
  done
  if [[ "${status}" != healthy ]]; then
    docker logs "${container}" >&2 || true
  fi
  assert_equal "${status}" healthy
}

# --- production reference ----------------------------------------------------------------------------------------

@test "the production reference renders with limits, read-only root, dropped capabilities and no-new-privileges" {
  require_docker
  run render_production_reference DATABASE_URL=postgres://app:unused@db.example.invalid:5432/app AWS_REGION=eu-west-1
  assert_success
  local rendered="${output}"
  run jq -e '.services.app.deploy.resources.limits | .cpus == 1 and .memory == "268435456" and .pids == 256' <<<"${rendered}"
  assert_success
  run jq -e '.services.migrate.deploy.resources.limits | .cpus == 0.5 and .memory == "134217728"' <<<"${rendered}"
  assert_success
  local service
  for service in app migrate; do
    run jq -e --arg service "${service}" '.services[$service] | .read_only == true and .cap_drop == ["ALL"]
      and .security_opt == ["no-new-privileges:true"]' <<<"${rendered}"
    assert_success
  done
  run jq -e '.services.app.environment | .APP_ENV == "prod" and (has("AWS_ENDPOINT_URL_SQS") | not)' <<<"${rendered}"
  assert_success
}

@test "the production reference rendered with --env-file /dev/null fails and names DATABASE_URL" {
  require_docker
  run render_production_reference
  assert_failure
  assert_output --partial 'DATABASE_URL is required'
}
