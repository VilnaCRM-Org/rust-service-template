#!/usr/bin/env bats
# Tests of the database targets of the development database (architecture-delivery.md "CLI Tests (Bats)", file
# make_database.bats): `migrate`, `migrate-rollback` and `create-migration`.

bats_require_minimum_version 1.8.0
load test_helper

# bats file_tags=quality

setup() {
  _common_setup
  require_docker
}

teardown() {
  restore_planted
  # A test that stopped after a rollback leaves the development database migrated again.
  if [[ -n "${migrated_in_teardown:-}" ]]; then
    make --no-print-directory migrate >/dev/null 2>&1 || true
  fi
}

# Runs a statement against the development database `app` in the database container of the compose project.
dev_sql() {
  "${DOCKER:-docker}" compose exec -T database psql --quiet --no-psqlrc --tuples-only --no-align -U app -d app -c "$1"
}

# The schema of the development database without data; pg_dump writes a random \restrict token that is removed.
schema() {
  "${DOCKER:-docker}" compose exec -T database pg_dump --schema-only -U app -d app | grep -v -E '^\\(un)?restrict '
}

@test "migrate twice: the second run applies nothing and changes nothing" {
  migrated_in_teardown=1
  run make --no-print-directory migrate
  assert_success
  local before after
  before="$(dev_sql 'select version, checksum from _sqlx_migrations order by version')"
  run make --no-print-directory migrate
  assert_success
  assert_output --partial 'applied 0 migration(s)'
  after="$(dev_sql 'select version, checksum from _sqlx_migrations order by version')"
  [[ -n "${before}" ]]
  [[ "${before}" == "${after}" ]]
}

@test "migrate-rollback then migrate restores the schema" {
  migrated_in_teardown=1
  run make --no-print-directory migrate
  assert_success
  local before rolled_back after
  before="$(schema)"
  run make --no-print-directory migrate-rollback
  assert_success
  rolled_back="$(schema)"
  [[ "${before}" != "${rolled_back}" ]]
  run make --no-print-directory migrate
  assert_success
  assert_output --partial 'applied 1 migration(s)'
  after="$(schema)"
  [[ -n "${before}" ]]
  [[ "${before}" == "${after}" ]]
}

@test "create-migration without name fails with the usage line and creates nothing" {
  local before after
  before="$(tree_status)"
  run make --no-print-directory create-migration
  assert_failure
  assert_output --partial 'Usage: make create-migration name=<snake_case_description>'
  assert_output --partial 'create-migration] Error 2'
  after="$(tree_status)"
  [[ "${before}" == "${after}" ]]
}
