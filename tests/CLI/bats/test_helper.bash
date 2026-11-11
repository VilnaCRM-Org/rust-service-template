# Shared helpers of the Makefile tests (architecture-delivery.md "CLI Tests (Bats)").
#
# Files that a test plants in the working tree are registered in target/bats-restore/manifest before they
# change and are restored by `restore_planted`, which every teardown calls and which `_common_setup` calls
# first, so the leftovers of an interrupted run are repaired before any test.

RESTORE_DIR_NAME=target/bats-restore

# Variables of the outer `make bats ...` call must not decide what the nested makes of the tests see. GNU make
# hands a command-line variable (`make bats BATS_ARGS=x CI_STAGES=y`) to every child twice: as an exported
# environment variable and, with command-line precedence, in MAKEFLAGS (MAKEOVERRIDES holds the same list), so
# unsetting MAKEFLAGS alone changes the precedence but not the presence of the variable. This removes both. The
# variables dropped are every caller-settable parameter and test hook that the Makefile and make/*.mk declare with a
# plain `NAME ?=` (BATS_ARGS, BATS_PATH, CI_STAGES, DEPS, base_ref, ...), read from the files so that a new one needs
# no edit here. What the suite takes from its caller stays: the execution switches (RUN_IN_CONTAINER, CI,
# IN_DEV_CONTAINER) and every exported setting (`export NAME ?=`: DOCKER, DOCKER_COMPOSE, BUILD_IMAGE, APP_IMAGE,
# DEV_IMAGE, LOAD_TEST_PROJECT, COMPOSE_PROJECT_NAME, ...), plus DB_PORT and LOCALSTACK_PORT, which are not declared
# in the Makefile at all.
isolate_make_environment() {
  local root name
  root="${REPO_ROOT:-$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)}"
  unset MAKEFLAGS MFLAGS MAKEOVERRIDES MAKELEVEL
  while IFS= read -r name; do
    unset "${name}"
  done < <(sed -n -E 's/^([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*\?=.*/\1/p' "${root}/Makefile" "${root}"/make/*.mk |
    grep -v -x -e RUN_IN_CONTAINER -e CI -e IN_DEV_CONTAINER || true)
}

# Repository root, libraries, working directory, and repair of an earlier interrupted run.
_common_setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  export REPO_ROOT
  bats_load_library bats-support
  bats_load_library bats-assert
  bats_load_library bats-file
  cd "${REPO_ROOT}" || return 1
  # Approval overrides of the caller must not reach the tests: only a test that sets one itself sees it.
  unset CONFIG_CHANGE_APPROVED BREAKING_CHANGE_APPROVED ALLOW_PROTECTED_CONFIG_EDIT
  # Tool output must be colourless whatever the caller exported (the hosted runner sets CARGO_TERM_COLOR=always).
  export CARGO_TERM_COLOR=never NO_COLOR=1
  unset CLICOLOR_FORCE FORCE_COLOR
  isolate_make_environment
  restore_planted
}

_restore_dir() {
  printf '%s/%s' "${REPO_ROOT}" "${RESTORE_DIR_NAME}"
}

_manifest() {
  printf '%s/manifest' "$(_restore_dir)"
}

# Path of a file relative to the repository root.
_relative() {
  local path="$1"
  printf '%s' "${path#"${REPO_ROOT}"/}"
}

# Whether the manifest already records a path (a second plant of the same file keeps the first backup).
_is_registered() {
  [[ -f "$(_manifest)" ]] && grep -Fq -- "	$1	" "$(_manifest)"
}

# Skips the test when the path has uncommitted changes, so that the work of a developer is never overwritten.
_refuse_if_dirty() {
  local rel="$1" status
  if _is_registered "${rel}"; then
    return 0
  fi
  status="$(git -C "${REPO_ROOT}" status --porcelain --ignored=no -- "${rel}")"
  if [[ -n "${status}" ]]; then
    skip "refusing to plant into ${rel}: it has uncommitted changes (${status})"
  fi
}

# Copies the original of a file into the restore directory and records it. $1 kind (file or keep), $2 relative path.
_backup() {
  local kind="$1" rel="$2" n backup
  mkdir -p "$(_restore_dir)/files"
  n=0
  if [[ -f "$(_manifest)" ]]; then
    n="$(wc -l <"$(_manifest)")"
  fi
  backup="files/${n// /}"
  cp --preserve=mode "${REPO_ROOT}/${rel}" "$(_restore_dir)/${backup}"
  printf '%s\t%s\t%s\n' "${kind}" "${rel}" "${backup}" >>"$(_manifest)"
}

# Appends the content of a fixture to a tracked file.
plant_append() {
  local file="$1" fixture="$2" rel
  rel="$(_relative "${file}")"
  _refuse_if_dirty "${rel}"
  _is_registered "${rel}" || _backup file "${rel}"
  cat "${fixture}" >>"${REPO_ROOT}/${rel}"
}

# Replaces a tracked file with the content of another file.
plant_replace() {
  local file="$1" content="$2" rel
  rel="$(_relative "${file}")"
  _refuse_if_dirty "${rel}"
  _is_registered "${rel}" || _backup file "${rel}"
  cat "${content}" >"${REPO_ROOT}/${rel}"
}

# Registers a tracked file that a tool is about to rewrite (for example Cargo.lock).
plant_keep() {
  local file="$1" rel
  rel="$(_relative "${file}")"
  _refuse_if_dirty "${rel}"
  _is_registered "${rel}" || _backup keep "${rel}"
}

# Creates a file that does not exist from a fixture; the missing parent directories are recorded too.
plant_new() {
  local path="$1" fixture="$2" rel dir parent
  local -a created=()
  rel="$(_relative "${path}")"
  if [[ -e "${REPO_ROOT}/${rel}" ]] && ! _is_registered "${rel}"; then
    skip "refusing to plant ${rel}: the path exists"
  fi
  mkdir -p "$(_restore_dir)"
  dir="$(dirname "${rel}")"
  parent="${dir}"
  while [[ "${parent}" != "." && ! -d "${REPO_ROOT}/${parent}" ]]; do
    created+=("${parent}")
    parent="$(dirname "${parent}")"
  done
  for parent in "${created[@]}"; do
    printf 'dir\t%s\t-\n' "${parent}" >>"$(_manifest)"
  done
  _is_registered "${rel}" || printf 'new\t%s\t-\n' "${rel}" >>"$(_manifest)"
  mkdir -p "${REPO_ROOT}/${dir}"
  cat "${fixture}" >"${REPO_ROOT}/${rel}"
}

# Registers a directory tree that a tool is about to create (for example crates/bats-group); the restore removes
# it with everything below. Nothing is registered, and so nothing is removed later, when the path already exists.
plant_tree() {
  local rel
  rel="$(_relative "$1")"
  [[ ! -e "${REPO_ROOT}/${rel}" ]] || return 0
  mkdir -p "$(_restore_dir)"
  _is_registered "${rel}" || printf 'tree\t%s\t-\n' "${rel}" >>"$(_manifest)"
}

# Registers a path whose index entry a test is about to change (`git add`); the restore unstages it again.
plant_index() {
  local rel
  rel="$(_relative "$1")"
  mkdir -p "$(_restore_dir)"
  printf 'index\t%s\t-\n' "${rel}" >>"$(_manifest)"
}

# Replays the manifest in reverse and deletes it. Safe to call when nothing was planted.
restore_planted() {
  local manifest kind rel backup
  manifest="$(_manifest)"
  [[ -f "${manifest}" ]] || return 0
  while IFS=$'\t' read -r kind rel backup; do
    case "${kind}" in
      file | keep) cp --preserve=mode "$(_restore_dir)/${backup}" "${REPO_ROOT}/${rel}" ;;
      new) rm -f -- "${REPO_ROOT}/${rel}" ;;
      dir) rmdir -- "${REPO_ROOT}/${rel}" 2>/dev/null || true ;;
      tree) rm -rf -- "${REPO_ROOT:?}/${rel}" ;;
      index) git -C "${REPO_ROOT}" restore --staged -- "${rel}" >/dev/null 2>&1 || true ;;
      *) ;;
    esac
  done < <(tac "${manifest}")
  rm -rf -- "$(_restore_dir)"
  return 0
}

# Skips the test when the container engine is not reachable.
require_docker() {
  "${DOCKER:-docker}" info >/dev/null 2>&1 || skip "a reachable container engine (docker) is required"
}

# Skips the test when a command is not on PATH.
require_command() {
  command -v "$1" >/dev/null 2>&1 || skip "the command '$1' is required"
}

# Value of a Make variable after the Makefile was read, so the tests follow the caller's environment.
make_value() {
  make --no-print-directory --silent -f Makefile -f - "print-$1" <<'MAKEFILE'
.RECIPEPREFIX = >
print-%:
> @printf '%s' "$($*)"
MAKEFILE
}

# Skips the test when the Makefile runs the tool targets inside the development container (container mode): the
# scenario needs the host environment, which that mode does not forward ($1: why).
require_host_mode() {
  [[ -z "$(make_value EXEC)" ]] || skip "$1 (not available in container mode)"
}

# Value of `export NAME := value` in make/tool-versions.mk.
pinned_value() {
  sed -n -E "s/^export[[:space:]]+$1[[:space:]]*:=[[:space:]]*(.*[^[:space:]])[[:space:]]*$/\1/p" \
    "${REPO_ROOT}/make/tool-versions.mk" | head -n 1
}

# `git status --porcelain` of the repository, for before and after comparisons.
tree_status() {
  git -C "${REPO_ROOT}" status --porcelain
}
