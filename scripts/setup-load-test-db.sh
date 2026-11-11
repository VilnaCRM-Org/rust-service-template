#!/usr/bin/env bash
# Drop, create and migrate the database of the isolated load-test environment.
#
# Usage: setup-load-test-db.sh
# Acts only on the compose project $LOAD_TEST_PROJECT (default: <directory name>-load), always with the explicit file
# list of the isolated environment: `dropdb --if-exists --force` and `createdb` in its `database` container, then
# `docker compose run --rm migrate`. It refuses to run when that project has no running `database` container.
# Exit status: 0 success; 1 a step failed; 2 the project is not running or is not an isolated project.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

default_project="$(basename "$ROOT" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_\n-' '-')-load"
project="${LOAD_TEST_PROJECT:-$default_project}"
db_user="${DB_USER:-app}"
db_name="${DB_NAME:-app}"

# The development project must never be the target: refuse when the names are the same.
if [ -z "$project" ] || [ "$project" = "${COMPOSE_PROJECT_NAME-}" ]; then
  echo "setup-load-test-db.sh: refusing to act on project '${project}': it must differ from the development project" >&2
  exit 2
fi

compose() {
  docker compose -p "$project" -f docker-compose.yml -f docker-compose.load_test.override.yml "$@"
}

if [ -z "$(compose ps --status running -q database 2>/dev/null)" ]; then
  echo "setup-load-test-db.sh: project '${project}' is not running; start it with scripts/with-load-test-stack.sh" >&2
  exit 2
fi

compose exec -T database dropdb -U "$db_user" --if-exists --force "$db_name" || exit 1
compose exec -T database createdb -U "$db_user" "$db_name" || exit 1
compose run --rm --no-deps migrate || exit 1
