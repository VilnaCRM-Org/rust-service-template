#!/usr/bin/env bash
# Repository invariants (gate G31, FR125): pins, toolchain agreement, gate set, repository name, licence,
# blanket suppressions and the execution switch. One rule per letter:
#   (a) workflow hygiene: pinned actions, permissions, concurrency, timeouts
#   (b) pinned images, tools, features and downloads
#   (c) one toolchain version in rust-toolchain.toml, the builder image tag and rust-version
#   (d) the gate set of `make ci-list` equals the gate set of the workflows; Bats groups; required checks
#   (e) the repository name occurs only where DD-23 allows it
#   (f) the licence identifier is CC0-1.0 everywhere it is stated
#   (g) no `allow` attribute, no `expect` in a crate root, no lint group in an `allow` or `expect`
#   (h) toolchain commands run behind $(EXEC)
#
# Usage: check-invariants.sh [--root <dir>]
# Prints one line per violation, prefixed with the rule letter, and nothing otherwise.
# Exit status: 0 no violation; 1 at least one violation; 2 the script could not run.
set -euo pipefail

usage() {
  echo 'usage: check-invariants.sh [--root <dir>]' >&2
  exit 2
}

root=''
while (($#)); do
  case "$1" in
    --root)
      (($# >= 2)) || usage
      root=$2
      shift 2
      ;;
    --root=*)
      root=${1#--root=}
      shift
      ;;
    *) usage ;;
  esac
done
if [[ -z "${root}" ]]; then
  root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fi
if [[ ! -d "${root}" ]]; then
  echo "check-invariants: no such directory: ${root}" >&2
  exit 2
fi
cd "${root}"

# The repository name is assembled so that this script, a file of a searched class, does not contain it.
repository_name='rust-service-'
repository_name+='template'

# Toolchain commands (G31 rule (h)).
tool_words='cargo|sqlx|taplo|typos|zizmor'

findings=0

# Prints every line of standard input and remembers that there was one.
emit() {
  local line
  while IFS= read -r line; do
    printf '%s\n' "${line}"
    findings=1
  done
  return 0
}

# Prints one violation: <rule> <message>.
report() {
  printf '(%s) %s\n' "$1" "$2"
  findings=1
  return 0
}

# Lists the files below the given directories (those that exist), sorted, one per line.
list_files() {
  local dir
  for dir in "$@"; do
    [[ -d "${dir}" ]] || continue
    find "${dir}" \( -name target -o -name node_modules -o -name .git \) -prune -o -type f -print
  done | LC_ALL=C sort
  return 0
}

# Value of `export NAME := value` (or `?=`) in make/tool-versions.mk; empty when absent.
pin() {
  [[ -f make/tool-versions.mk ]] || return 0
  sed -n -E "s/^export[[:space:]]+$1[[:space:]]*[:?]?=[[:space:]]*(.*[^[:space:]])[[:space:]]*\$/\1/p" make/tool-versions.mk | head -n 1
  return 0
}

workflows=()
while IFS= read -r file; do
  workflows+=("${file}")
done < <(find .github/workflows -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null | LC_ALL=C sort || true)

compose_files=()
while IFS= read -r file; do
  compose_files+=("${file}")
done < <(find . -maxdepth 1 -type f \( -name 'docker-compose*.yml' -o -name 'docker-compose*.yaml' -o -name 'compose*.yml' -o -name 'compose*.yaml' \) -print 2>/dev/null | sed 's|^\./||' | LC_ALL=C sort || true)

make_files=()
[[ -f Makefile ]] && make_files+=(Makefile)
while IFS= read -r file; do
  make_files+=("${file}")
done < <(find make -maxdepth 1 -type f -name '*.mk' 2>/dev/null | LC_ALL=C sort || true)

# Prints the command lines of the `run:` steps of a workflow as `<line number>:<text>`.
workflow_run_lines() {
  awk '
    function indent(s) { match(s, /^ */); return RLENGTH }
    block && (indent($0) > base || $0 ~ /^[[:space:]]*$/) { print NR ":" $0; next }
    { block = 0 }
    /^[[:space:]]*#/ { next }
    /^[[:space:]-]*run:[[:space:]]*/ {
      v = $0
      sub(/^[^:]*run:[[:space:]]*/, "", v)
      if (v ~ /^[|>][-+0-9]*[[:space:]]*(#.*)?$/) { block = 1; base = indent($0); next }
      print NR ":" v
    }
  ' "$1"
  return 0
}

# ---------------------------------------------------------------------------------------------------------------
# (a) Workflows
# ---------------------------------------------------------------------------------------------------------------
check_workflow_hygiene() {
  local file=$1
  awk -v exempt_list='release sync' '
    function out(msg) { print "(a) " FILENAME ": " msg }
    function flush_job() {
      if (job != "") {
        if (!has_timeout) out("job " job " has no timeout-minutes")
        if (has_perm && !perm_ok && !(job in exempt)) out("job " job " has a permissions block without contents: read")
      }
      job = ""
    }
    BEGIN {
      n = split(exempt_list, e, " ")
      for (i = 1; i <= n; i++) exempt[e[i]] = 1
    }
    /^[[:space:]]*#/ { next }
    /^permissions:/ { top_perm = 1 }
    /^concurrency:/ { top_conc = 1 }
    /^[[:space:]-]*uses:/ {
      v = $0
      sub(/^[^:]*uses:[[:space:]]*/, "", v)
      sub(/[[:space:]]*#.*$/, "", v)
      gsub(/["\047]/, "", v)
      if (v !~ /^\.\// && v !~ /^docker:\/\//) {
        at = index(v, "@")
        ref = at ? substr(v, at + 1) : ""
        if (length(ref) != 40 || ref !~ /^[0-9a-f]+$/) out("line " NR ": uses: " v " is not pinned to a 40-character commit SHA")
      }
    }
    /^jobs:/ { in_jobs = 1; next }
    in_jobs && /^[^[:space:]#]/ { flush_job(); in_jobs = 0 }
    in_jobs && /^  [A-Za-z0-9_-]+:[[:space:]]*(#.*)?$/ {
      flush_job()
      job = $1
      sub(/:$/, "", job)
      has_timeout = 0; has_perm = 0; perm_ok = 0; in_perm = 0
      next
    }
    in_jobs && job != "" {
      if ($0 ~ /^    timeout-minutes:/) has_timeout = 1
      if ($0 ~ /^    permissions:/) {
        has_perm = 1; in_perm = 1
        if ($0 ~ /contents:[[:space:]]*read/) perm_ok = 1
        next
      }
      if (in_perm) {
        if ($0 ~ /^      /) { if ($0 ~ /contents:[[:space:]]*read/) perm_ok = 1 }
        else if ($0 !~ /^[[:space:]]*$/) in_perm = 0
      }
    }
    END {
      flush_job()
      if (!top_perm) out("the workflow declares no permissions")
      if (!top_conc) out("the workflow declares no concurrency")
    }
  ' "${file}"
  return 0
}

rule_a() {
  local file
  for file in "${workflows[@]}"; do
    emit < <(check_workflow_hygiene "${file}")
  done
  return 0
}

# ---------------------------------------------------------------------------------------------------------------
# (b) Pins
# ---------------------------------------------------------------------------------------------------------------
# <where> <reference>: tag and digest required, `latest` refused.
check_image_ref() {
  local where=$1 ref=$2 repo_tag tag
  if [[ ! "${ref}" =~ @sha256:[0-9a-f]{64}$ ]]; then
    report b "${where}: image ${ref} has no digest"
  fi
  repo_tag=${ref%%@*}
  if [[ "${repo_tag##*/}" != *:* ]]; then
    report b "${where}: image ${ref} has no version tag"
    return 0
  fi
  tag=${repo_tag##*:}
  if [[ "${tag}" == latest ]]; then
    report b "${where}: image ${ref} uses the tag latest"
  fi
  return 0
}

check_dockerfile_images() {
  local file=$1 line number=0 image rest lower
  local in_directives=1
  local -a stages=()
  while IFS= read -r line || [[ -n "${line}" ]]; do
    number=$((number + 1))
    # The BuildKit frontend named by the `# syntax=` parser directive is an image that parses and runs the
    # build: it needs a version tag and a digest like every other image. Parser directives stand at the top,
    # before the first line that is not a directive.
    if [[ "${in_directives}" == 1 ]]; then
      if [[ "${line}" =~ ^#[[:space:]]*[Ss][Yy][Nn][Tt][Aa][Xx][[:space:]]*=[[:space:]]*([^[:space:]]+) ]]; then
        check_image_ref "${file}:${number}" "${BASH_REMATCH[1]}"
        continue
      fi
      in_directives=0
    fi
    [[ "${line}" =~ ^[[:space:]]*[Ff][Rr][Oo][Mm][[:space:]]+(.*)$ ]] || continue
    rest=${BASH_REMATCH[1]}
    # shellcheck disable=SC2206
    local -a words=(${rest})
    image=''
    local word
    for word in "${words[@]}"; do
      [[ "${word}" == --* ]] && continue
      image=${word}
      break
    done
    [[ -n "${image}" ]] || continue
    lower=$(printf '%s' "${image}" | tr '[:upper:]' '[:lower:]')
    if [[ "${lower}" != scratch ]] && ! printf '%s\n' "${stages[@]+"${stages[@]}"}" | grep -qxF -- "${lower}"; then
      check_image_ref "${file}:${number}" "${image}"
    fi
    if [[ "${#words[@]}" -ge 3 ]] && [[ "$(printf '%s' "${words[-2]}" | tr '[:upper:]' '[:lower:]')" == as ]]; then
      stages+=("$(printf '%s' "${words[-1]}" | tr '[:upper:]' '[:lower:]')")
    fi
  done <"${file}"
  return 0
}

check_compose_images() {
  local file=$1 service value number
  while IFS=$'\t' read -r number service value; do
    if [[ "${service}" == database && "${value}" =~ ^postgres:\$\{DB_VERSION:-[0-9]+\}-alpine$ ]]; then
      continue
    fi
    if [[ "${value}" =~ ^\$\{(APP_IMAGE|DEV_IMAGE):-[^}]+\}$ ]]; then
      continue
    fi
    check_image_ref "${file}:${number}" "${value}"
  done < <(awk '
    /^[[:space:]]*#/ { next }
    /^services:/ { in_services = 1; next }
    in_services && /^[^[:space:]#]/ { in_services = 0 }
    in_services && /^  [A-Za-z0-9_.-]+:[[:space:]]*(#.*)?$/ { service = $1; sub(/:$/, "", service); next }
    in_services && /^    image:/ {
      v = $0
      sub(/^    image:[[:space:]]*/, "", v)
      sub(/[[:space:]]*#.*$/, "", v)
      gsub(/["\047]/, "", v)
      print NR "\t" service "\t" v
    }
  ' "${file}")
  return 0
}

check_tool_versions_file() {
  local line name value
  [[ -f make/tool-versions.mk ]] || return 0
  while IFS= read -r line; do
    [[ "${line}" =~ ^export[[:space:]]+([A-Z0-9_]+)[[:space:]]*[:?]?=[[:space:]]*(.*[^[:space:]])[[:space:]]*$ ]] || continue
    name=${BASH_REMATCH[1]}
    value=${BASH_REMATCH[2]}
    case "${name}" in
      *_IMAGE) check_image_ref "make/tool-versions.mk: ${name}" "${value}" ;;
      *SHA256*)
        [[ "${value}" =~ ^[0-9a-f]{64}$ ]] || report b "make/tool-versions.mk: ${name} is not a SHA-256 checksum"
        ;;
      BATS_*)
        [[ "${value}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+[[:space:]]+[0-9a-f]{40}$ ]] \
          || report b "make/tool-versions.mk: ${name} is not an exact tag followed by a 40-character commit SHA"
        ;;
      *_VERSION)
        [[ "${value}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || report b "make/tool-versions.mk: ${name} has no exact version (${value})"
        ;;
      *) ;;
    esac
  done <make/tool-versions.mk
  return 0
}

# Name of the pin of a tool of a `tool:` entry: cargo-nextest -> CARGO_NEXTEST_VERSION, taplo-cli -> TAPLO_VERSION.
tool_pin_name() {
  local base candidate
  base=$(printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_')
  for candidate in "${base}" "${base%_CLI}" "CARGO_${base}"; do
    if [[ -n "$(pin "${candidate}_VERSION")" ]]; then
      printf '%s_VERSION' "${candidate}"
      return 0
    fi
  done
  return 1
}

check_workflow_pins() {
  local file=$1 line number value entry name version pin_name pinned found cmd package
  while IFS= read -r line; do
    number=${line%%:*}
    value=${line#*:}
    [[ "${value}" =~ ^[[:space:]-]*tool:[[:space:]]*(.*)$ ]] || continue
    value=${BASH_REMATCH[1]}
    value=${value%%[[:space:]]#*}
    value=${value//[\"\']/}
    for entry in ${value//,/ }; do
      name=${entry%%@*}
      if [[ "${entry}" != *@* ]]; then
        report b "${file}:${number}: tool ${name} has no exact version"
        continue
      fi
      version=${entry#*@}
      if [[ ! "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        report b "${file}:${number}: tool ${name} has no exact version (${version})"
        continue
      fi
      if ! pin_name=$(tool_pin_name "${name}"); then
        report b "${file}:${number}: tool ${name} has no pin in make/tool-versions.mk"
        continue
      fi
      pinned=$(pin "${pin_name}")
      if [[ "${version}" != "${pinned}" ]]; then
        report b "${file}:${number}: tool ${name}@${version} differs from ${pin_name} ${pinned} in make/tool-versions.mk"
      fi
    done
  done < <(grep -nE '^[[:space:]-]*tool:' "${file}" || true)

  pinned=$(pin DEVCONTAINER_CLI_VERSION)
  while IFS= read -r found; do
    [[ -n "${found}" ]] || continue
    version=${found#*@devcontainers/cli@}
    if [[ "${version}" != "${pinned}" ]]; then
      report b "${file}: @devcontainers/cli@${version} differs from DEVCONTAINER_CLI_VERSION ${pinned} in make/tool-versions.mk"
    fi
  done < <(grep -ohE '@devcontainers/cli@[^[:space:]"'"'"']+' "${file}" || true)

  while IFS= read -r line; do
    number=${line%%:*}
    cmd=${line#*:}
    if [[ "${cmd}" =~ npx([[:space:]]+-{1,2}[A-Za-z-]+)*[[:space:]]+([^[:space:]-][^[:space:]]*) ]]; then
      package=${BASH_REMATCH[2]}
      if [[ ! "${package}" =~ @[0-9]+\.[0-9]+\.[0-9]+ ]]; then
        report b "${file}:${number}: npx runs ${package} without an exact version"
      fi
    fi
  done < <(workflow_run_lines "${file}" | grep -E 'npx' || true)
  return 0
}

check_workflow_images() {
  local file=$1 line number value
  while IFS= read -r line; do
    number=${line%%:*}
    value=${line#*:}
    [[ "${value}" =~ ^[[:space:]-]*(image|container):[[:space:]]*([^[:space:]#]+) ]] || continue
    value=${BASH_REMATCH[2]}
    value=${value//[\"\']/}
    [[ "${value}" == *"\${{"* || "${value}" == '|' || "${value}" == '{' ]] && continue
    check_image_ref "${file}:${number}" "${value}"
  done < <(grep -nE '^[[:space:]-]*(image|container):[[:space:]]*[^[:space:]#]' "${file}" || true)
  return 0
}

check_devcontainer_features() {
  local file=.devcontainer/devcontainer.json key
  [[ -f "${file}" ]] || return 0
  while IFS= read -r key; do
    [[ -n "${key}" ]] || continue
    if [[ ! "${key}" =~ @sha256:[0-9a-f]{64}$ ]]; then
      report b "${file}: feature ${key} is not referenced by digest"
    fi
  done < <(awk '
    /^[[:space:]]*\/\// { next }
    {
      line = $0
      if (!in_features) {
        if (line ~ /"features"[[:space:]]*:[[:space:]]*\{/) { in_features = 1; depth = 1 }
        next
      }
      if (depth == 1 && match(line, /"[^"]+"[[:space:]]*:/)) {
        key = substr(line, RSTART + 1, RLENGTH - 1)
        sub(/".*$/, "", key)
        print key
      }
      stripped = line
      gsub(/"[^"]*"/, "", stripped)
      opens = gsub(/\{/, "{", stripped)
      closes = gsub(/\}/, "}", stripped)
      depth += opens - closes
      if (depth <= 0) in_features = 0
    }
  ' "${file}")
  return 0
}

# One version of cargo-chef and of Structurizr in every file that states it.
check_pinned_copies() {
  local file chef structurizr found
  chef=$(pin CARGO_CHEF_VERSION)
  structurizr=$(pin STRUCTURIZR_IMAGE)
  for file in Dockerfile "${compose_files[@]+"${compose_files[@]}"}" "${workflows[@]+"${workflows[@]}"}"; do
    [[ -f "${file}" ]] || continue
    while IFS= read -r found; do
      [[ -n "${found}" ]] || continue
      if [[ "${found}" != "${chef}" ]]; then
        report b "${file}: cargo-chef ${found} differs from CARGO_CHEF_VERSION ${chef} in make/tool-versions.mk"
      fi
    done < <({
      grep -hoE 'CARGO_CHEF_VERSION[=:][[:space:]]*"?[0-9][0-9.]*' "${file}" | sed -E 's/.*[=:][[:space:]]*"?//' || true
      grep -hoE 'cargo install cargo-chef[^#]*--version[ =]"?[0-9][0-9.]*' "${file}" | sed -E 's/.*--version[ =]"?//' || true
    })
    while IFS= read -r found; do
      [[ -n "${found}" ]] || continue
      if [[ "${found}" != "${structurizr}" ]]; then
        report b "${file}: ${found} differs from STRUCTURIZR_IMAGE ${structurizr} in make/tool-versions.mk"
      fi
    done < <(grep -hoE 'structurizr/structurizr:[^[:space:]"'"'"']+' "${file}" || true)
  done
  return 0
}

check_cargo_install_versions() {
  local file=$1 line
  while IFS= read -r line; do
    if [[ "${line}" != *--version* && "${line}" != *'--version '* ]]; then
      report b "${file}: ${line%%[[:space:]]#*} has no exact version"
    fi
  done < <(grep -hE '^[[:space:]]*(RUN[[:space:]]+)?cargo install[[:space:]]' "${file}" | sed -E 's/^[[:space:]]+//' || true)
  return 0
}

check_downloads() {
  local file
  for file in Dockerfile "${make_files[@]+"${make_files[@]}"}" "${workflows[@]+"${workflows[@]}"}" $(list_files scripts); do
    [[ -f "${file}" ]] || continue
    if grep -vE '^[[:space:]]*#' "${file}" \
      | grep -qE '\b(curl|wget)\b[^#]*(https?://|--output|--remote-name|[[:space:]]-[A-Za-z]*[oOL][A-Za-z]*[[:space:]]|--location|--fail)'; then
      if ! grep -qiE 'sha256|sha512|shasum|checksum' "${file}"; then
        report b "${file}: a file is downloaded by URL without a checksum"
      fi
    fi
  done
  return 0
}

rule_b() {
  local file
  [[ -f Dockerfile ]] && check_dockerfile_images Dockerfile
  [[ -f Dockerfile ]] && check_cargo_install_versions Dockerfile
  for file in "${compose_files[@]+"${compose_files[@]}"}"; do
    check_compose_images "${file}"
  done
  check_tool_versions_file
  for file in "${workflows[@]+"${workflows[@]}"}"; do
    check_workflow_images "${file}"
    check_workflow_pins "${file}"
  done
  check_devcontainer_features
  check_pinned_copies
  check_downloads
  return 0
}

# ---------------------------------------------------------------------------------------------------------------
# (c) One toolchain version
# ---------------------------------------------------------------------------------------------------------------
rule_c() {
  local channel='' builder='' manifest='' line full='^[0-9]+\.[0-9]+\.[0-9]+$'
  if [[ -f rust-toolchain.toml ]]; then
    channel=$(sed -n -E 's/^channel[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/p' rust-toolchain.toml | head -n 1)
  fi
  if [[ -f Dockerfile ]]; then
    line=$(grep -m1 -E '^[[:space:]]*FROM[[:space:]]+(--[^[:space:]]+[[:space:]]+)*rust:' Dockerfile || true)
    builder=$(printf '%s' "${line}" | sed -n -E 's/.*[[:space:]]rust:([^@[:space:]-]+).*/\1/p')
  fi
  if [[ -f Cargo.toml ]]; then
    manifest=$(sed -n -E 's/^rust-version[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/p' Cargo.toml | head -n 1)
  fi
  local label value
  for label in "rust-toolchain.toml channel:${channel}" "Dockerfile builder image tag:${builder}" "Cargo.toml rust-version:${manifest}"; do
    value=${label##*:}
    if [[ ! "${value}" =~ ${full} ]]; then
      report c "${label%%:*} is missing or is not a full version (found '${value}')"
    fi
  done
  if [[ "${channel}" == "${builder}" && "${channel}" == "${manifest}" ]]; then
    return 0
  fi
  report c "toolchain versions differ: rust-toolchain.toml ${channel:-none}, builder image ${builder:-none}, rust-version ${manifest:-none}"
  return 0
}

# ---------------------------------------------------------------------------------------------------------------
# (d) Gate set, Bats groups, required checks
# ---------------------------------------------------------------------------------------------------------------
# Make targets of the CI-only list of DD-02 and of the scheduled and release workflows: not gates of make ci.
ci_only_targets=' ci bootstrap check-commit-message mutation-tests static-analysis-sarif '
# Gates of make ci that the workflows reach without naming them in a make command: the test database through the
# prerequisites of validate-sqlx-metadata, and the production image through the buildx step (DD-02, S5).
indirect_targets=' setup-test-db build-prod-image '

make_command_re='(^|[;&|(]|then|do)[[:space:]]*make[[:space:]]+(.*)$'

# Make targets named by the `make` commands of the run steps of the given workflows, one per line.
workflow_make_targets() {
  local file line text word
  for file in "$@"; do
    while IFS= read -r line; do
      text=${line#*:}
      text=${text%%#*}
      [[ "${text}" =~ ${make_command_re} ]] || continue
      text=${BASH_REMATCH[2]}
      text=${text%%&&*}
      text=${text%%||*}
      text=${text%%|*}
      text=${text%%;*}
      text=${text%%[0-9]>*}
      text=${text%%>*}
      for word in ${text}; do
        [[ "${word}" == -* || "${word}" == *=* || "${word}" == '$'* || "${word}" == *'"'* || "${word}" == *"'"* ]] && continue
        printf '%s\n' "${word}"
      done
    done < <(workflow_run_lines "${file}" | grep -E 'make' || true)
  done | LC_ALL=C sort -u
  return 0
}

rule_d_gates() {
  local gates target ran
  if ! gates=$(make --no-print-directory -s -C "${root}" ci-list 2>/dev/null); then
    report d 'make ci-list failed: the gate targets cannot be read'
    return 0
  fi
  if ((${#workflows[@]} == 0)); then
    report d 'no workflow files in .github/workflows: no workflow runs any gate target of make ci-list'
    return 0
  fi
  ran=$(workflow_make_targets "${workflows[@]}")
  for target in ${gates}; do
    [[ "${indirect_targets}" == *" ${target} "* ]] && continue
    if ! grep -qxF -- "${target}" <<<"${ran}"; then
      report d "gate target ${target} of make ci-list is run by no workflow"
    fi
  done
  while IFS= read -r target; do
    [[ -n "${target}" ]] || continue
    [[ "${ci_only_targets}" == *" ${target} "* ]] && continue
    if ! grep -qxF -- "${target}" <<<"${gates}"; then
      report d "a workflow runs make ${target}, which is not a gate target of make ci-list"
    fi
  done <<<"${ran}"
  return 0
}

# Groups of the matrix of the job bats-group of tests.yml, one per line; the six groups of the architecture when
# the workflow does not exist yet.
bats_groups() {
  local groups=''
  if [[ -f .github/workflows/tests.yml ]]; then
    groups=$(awk '
      /^  [A-Za-z0-9_-]+:[[:space:]]*(#.*)?$/ { in_job = ($1 == "bats-group:") }
      in_job && /^[[:space:]-]*group:[[:space:]]*[A-Za-z0-9_-]+/ {
        v = $0
        sub(/^[^:]*group:[[:space:]]*/, "", v)
        sub(/[[:space:]]*(#.*)?$/, "", v)
        print v
      }
    ' .github/workflows/tests.yml)
  fi
  if [[ -z "${groups}" ]]; then
    groups=$'surface\nquality\ntests\ncontracts\nload\nrepository'
  fi
  printf '%s\n' "${groups}"
  return 0
}

rule_d_bats() {
  local groups file tags line count tag
  [[ -d tests/CLI/bats ]] || return 0
  groups=$(bats_groups)
  while IFS= read -r file; do
    tags=()
    while IFS= read -r line; do
      line=${line#*file_tags=}
      line=${line//[[:space:]]/}
      IFS=',' read -r -a parts <<<"${line}"
      tags+=("${parts[@]}")
    done < <(grep -E '^#[[:space:]]*bats[[:space:]]+file_tags=' "${file}" || true)
    count=${#tags[@]}
    if ((count != 1)); then
      report d "${file}: ${count} file tags, exactly one group tag is required"
      continue
    fi
    tag=${tags[0]}
    if ! grep -qxF -- "${tag}" <<<"${groups}"; then
      report d "${file}: file tag '${tag}' is not a group of the bats-group matrix"
    fi
  done < <(find tests/CLI/bats -maxdepth 1 -type f -name '*.bats' | LC_ALL=C sort)
  return 0
}

rule_d_required_checks() {
  local file job
  for file in "${workflows[@]+"${workflows[@]}"}"; do
    grep -qE '^[[:space:]]*(-[[:space:]]*)?pull_request[[:space:]]*:|^on:[[:space:]]*\[?.*\bpull_request\b' "${file}" || continue
    if [[ ! -f docs/repository-settings.md ]]; then
      report d "docs/repository-settings.md is missing: the jobs of ${file} are not listed"
      continue
    fi
    while IFS= read -r job; do
      [[ -n "${job}" ]] || continue
      # docs/repository-settings.md is synchronised from the template; the jobs of the workflows that a service
      # adds itself are listed in the optional, service-owned docs/repository-settings-service.md.
      if ! grep -qF -- "\`${job}\`" docs/repository-settings.md &&
        ! { [[ -f docs/repository-settings-service.md ]] && grep -qF -- "\`${job}\`" docs/repository-settings-service.md; }; then
        report d "${file}: job ${job} is missing from docs/repository-settings.md (or docs/repository-settings-service.md)"
      fi
    done < <(awk '
      /^jobs:/ { in_jobs = 1; next }
      in_jobs && /^[^[:space:]#]/ { in_jobs = 0 }
      in_jobs && /^  [A-Za-z0-9_-]+:[[:space:]]*(#.*)?$/ { j = $1; sub(/:$/, "", j); print j }
    ' "${file}")
  done
  return 0
}

rule_d() {
  rule_d_gates
  rule_d_bats
  rule_d_required_checks
  return 0
}

# ---------------------------------------------------------------------------------------------------------------
# (e) Repository name
# ---------------------------------------------------------------------------------------------------------------
rule_e() {
  local file hits
  local -a files=()
  while IFS= read -r file; do
    files+=("${file}")
  done < <({
    list_files .github/workflows scripts tests crates xtask features .claude/skills make
    for file in Makefile Dockerfile AGENTS.md CLAUDE.md "${compose_files[@]+"${compose_files[@]}"}"; do
      [[ -f "${file}" ]] && printf '%s\n' "${file}"
    done
  } | LC_ALL=C sort -u)
  for file in "${files[@]+"${files[@]}"}"; do
    hits=$(grep -nIF -- "${repository_name}" "${file}" || true)
    [[ -n "${hits}" ]] || continue
    case "${file}" in
      .github/workflows/template-sync-app.yml | .github/workflows/template-sync-pat.yml)
        hits=$(grep -vE '^[0-9]+:[[:space:]]*TEMPLATE_REPOSITORY:' <<<"${hits}" || true)
        ;;
      *) ;;
    esac
    [[ -n "${hits}" ]] || continue
    while IFS= read -r line; do
      report e "${file}:${line%%:*}: the repository name occurs outside the places DD-23 allows"
    done <<<"${hits}"
  done
  return 0
}

# ---------------------------------------------------------------------------------------------------------------
# (f) Licence
# ---------------------------------------------------------------------------------------------------------------
licence='CC0-1.0'

rule_f() {
  local file line number value
  while IFS= read -r file; do
    while IFS= read -r line; do
      number=${line%%:*}
      value=${line#*:}
      value=$(sed -n -E 's/^[[:space:]]*license[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/p' <<<"${value}")
      [[ -n "${value}" && "${value}" != "${licence}" ]] && report f "${file}:${number}: licence identifier ${value} (only ${licence} is allowed)"
    done < <(grep -nE '^[[:space:]]*license[[:space:]]*=' "${file}" || true)
  done < <(find . \( -name target -o -name node_modules -o -name .git \) -prune -o -type f -name Cargo.toml -print | sed 's|^\./||' | LC_ALL=C sort)

  if [[ -f LICENSE ]] && ! head -n 12 LICENSE | grep -qE 'CC0|Creative Commons Zero'; then
    report f 'LICENSE: the licence text is not CC0 1.0'
  fi

  if [[ -f README.md ]]; then
    while IFS= read -r line; do
      report f "README.md: the licence section names another licence: ${line}"
    done < <(awk '
      /^#+[[:space:]]+Licen[cs]e/ { in_section = 1; next }
      in_section && /^#/ { in_section = 0 }
      in_section && /(^|[^A-Za-z0-9.-])(MIT|Apache-2\.0|BSD-[0-9]-Clause|GPL-[0-9.]+|LGPL-[0-9.]+|AGPL-[0-9.]+|MPL-2\.0|ISC|Unlicense)([^A-Za-z0-9.-]|$)/ { print }
    ' README.md)
  fi

  if [[ -f .github/openapi-spec/spec.yaml ]]; then
    while IFS= read -r line; do
      report f ".github/openapi-spec/spec.yaml: info.license states ${line} (only ${licence} is allowed)"
    done < <(awk '
      /^[[:space:]]*license:[[:space:]]*$/ { in_license = 1; next }
      in_license && /^[[:space:]]*(name|identifier):/ {
        v = $0
        sub(/^[^:]*:[[:space:]]*/, "", v)
        gsub(/["\047]/, "", v)
        if (v != "'"${licence}"'") print v
        next
      }
      in_license && !/^[[:space:]]+/ { in_license = 0 }
      in_license && /^  [A-Za-z]/ { in_license = 0 }
    ' .github/openapi-spec/spec.yaml)
  fi

  local -a label_files=(Dockerfile "${compose_files[@]+"${compose_files[@]}"}")
  for file in "${label_files[@]}"; do
    [[ -f "${file}" ]] || continue
    while IFS= read -r value; do
      [[ -n "${value}" && "${value}" != "${licence}" ]] && report f "${file}: image label org.opencontainers.image.licenses is ${value} (only ${licence} is allowed)"
    done < <(grep -hoE 'org\.opencontainers\.image\.licenses[=:][[:space:]]*"?[^"[:space:]]*' "${file}" | sed -E 's/.*[=:][[:space:]]*"?//' || true)
  done

  while IFS= read -r file; do
    value=$(sed -n -E 's/^[[:space:]]*"license"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' "${file}" | head -n 1)
    [[ -n "${value}" && "${value}" != "${licence}" ]] && report f "${file}: licence identifier ${value} (only ${licence} is allowed)"
  done < <(find tests -name node_modules -prune -o -type f -name package.json -print 2>/dev/null | LC_ALL=C sort || true)
  return 0
}

# ---------------------------------------------------------------------------------------------------------------
# (g) Suppressions
# ---------------------------------------------------------------------------------------------------------------
rule_g() {
  local -a sources=()
  local file
  while IFS= read -r file; do
    sources+=("${file}")
  done < <(find . \( -name target -o -name node_modules -o -name .git -o -name '_bmad*' \) -prune -o -type f -name '*.rs' -print | sed 's|^\./||' | LC_ALL=C sort)
  ((${#sources[@]} > 0)) || return 0
  emit < <(awk '
    function out(msg) { print "(g) " FILENAME ":" start ": " msg }
    function is_root(path,   base, n, parts) {
      n = split(path, parts, "/")
      base = parts[n]
      if (base == "lib.rs" || base == "main.rs" || base == "build.rs") return 1
      return 0
    }
    function strip_strings(s) { gsub(/"[^"]*"/, "", s); return s }
    BEGIN {
      groups = "(warnings|unused|clippy::all|clippy::pedantic|clippy::nursery|clippy::cargo|clippy::restriction|clippy::complexity|clippy::style|clippy::perf|clippy::correctness|clippy::suspicious|rust_2018_idioms|future_incompatible|nonstandard_style)"
      group_re = "(^|[^A-Za-z0-9_:])" groups "([^A-Za-z0-9_]|$)"
    }
    FNR == 1 { collecting = 0; root = is_root(FILENAME) }
    /^[[:space:]]*\/\// { next }
    {
      line = $0
      if (!collecting && line ~ /#!?\[[[:space:]]*(allow|expect)([^A-Za-z0-9_]|$)/) {
        start = FNR
        kind = (line ~ /#!?\[[[:space:]]*allow/) ? "allow" : "expect"
        inner = (line ~ /#!\[/)
        if (kind == "allow") out("#[allow or #![allow is not permitted")
        if (kind == "expect" && inner && root) out("#![expect( in a crate root is not permitted")
        collecting = 1
        text = ""
      }
      if (collecting) {
        text = text " " line
        if (line ~ /\)[[:space:]]*\]/ || line ~ /^[[:space:]]*#!?\[[^(]*\]/) {
          if (strip_strings(text) ~ group_re) out("an " kind " names a lint group")
          collecting = 0
        }
      }
    }
  ' "${sources[@]}")
  return 0
}

# ---------------------------------------------------------------------------------------------------------------
# (h) Execution switch
# ---------------------------------------------------------------------------------------------------------------
rule_h() {
  local line script from base hits
  ((${#make_files[@]} > 0)) || return 0
  emit < <(awk -v tool_list="${tool_words//|/ }" '
    function first_word(s,   n, w, i, skip) {
      gsub(/"[^"]*"/, "Q", s)
      gsub(/\047[^\047]*\047/, "Q", s)
      n = split(s, w, /[[:space:]]+/)
      i = 1
      while (i <= n && w[i] == "") i++
      if (w[i] == "env") {
        i++
        while (i <= n) {
          if (w[i] == "-u") { i += 2; continue }
          if (w[i] ~ /^-/ || w[i] ~ /=/) { i++; continue }
          break
        }
      }
      return w[i]
    }
    BEGIN {
      n = split(tool_list, t, " ")
      for (i = 1; i <= n; i++) tools[t[i]] = 1
      tools["xtask"] = 1
      exempt["install"] = 1
    }
    FNR == 1 && FILENAME == ARGV[1] { pass++ }
    pass == 1 {
      line = $0
      sub(/^export[[:space:]]+/, "", line)
      if (match(line, /^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*(::=|:=|\?=|=)/)) {
        name = line
        sub(/[[:space:]]*(::=|:=|\?=|=).*$/, "", name)
        value = line
        sub(/^[^=]*=[[:space:]]*/, "", value)
        vars[name] = first_word(value)
      }
      next
    }
    {
      if (cont) { cont = ($0 ~ /\\$/); next }
      if ($0 ~ /^\t/) {
        cont = ($0 ~ /\\$/)
        cmd = $0
        sub(/^\t+/, "", cmd)
        sub(/^[@+-]+[[:space:]]*/, "", cmd)
        w = first_word(cmd)
        if (w in tools) {
          if (!(target in exempt)) print "(h) " FILENAME ":" FNR ": the recipe of " target " starts " w " without $(EXEC)"
        } else if (match(w, /^\$\([A-Za-z_][A-Za-z0-9_]*\)$/)) {
          v = substr(w, 3, length(w) - 3)
          if ((v in vars) && (vars[v] in tools) && !(target in exempt)) print "(h) " FILENAME ":" FNR ": the recipe of " target " starts " w " (" vars[v] ") without $(EXEC)"
        }
        next
      }
      if ($0 ~ /^[A-Za-z0-9_.%-]+([[:space:]]+[A-Za-z0-9_.%-]+)*[[:space:]]*:([^=]|$)/) {
        target = $0
        sub(/[[:space:]]*:.*$/, "", target)
        sub(/[[:space:]].*$/, "", target)
      }
    }
  ' "${make_files[@]}" "${make_files[@]}")

  # Scripts that a recipe calls outside $(EXEC): they start no toolchain command.
  hits=$(awk '
    $0 ~ /^\t/ {
      line = $0
      gsub(/&&|\|\||[|;]/, "\n", line)
      n = split(line, segs, "\n")
      for (i = 1; i <= n; i++) {
        if (index(segs[i], "$(EXEC)")) continue
        rest = segs[i]
        while (match(rest, /scripts\/[A-Za-z0-9_.\/-]+\.(sh|bash)/)) {
          print substr(rest, RSTART, RLENGTH) "\t" FILENAME ":" FNR
          rest = substr(rest, RSTART + RLENGTH)
        }
      }
    }
  ' "${make_files[@]}" | LC_ALL=C sort -u)
  while IFS=$'\t' read -r script from; do
    [[ -n "${script}" && -f "${script}" ]] || continue
    base=${script##*/}
    [[ "${base}" == install-tools.sh || "${base}" == doctor.sh ]] && continue
    while IFS= read -r line; do
      report h "${script}:${line%%:*}: called outside \$(EXEC) from ${from}, but starts a toolchain command"
    done < <(grep -nE "(^|[;&|(!]|\\\$\\()[[:space:]]*((then|do|exec|sudo|if|elif|while|until)[[:space:]]+)?(env[[:space:]]+([-A-Za-z0-9_=./]+[[:space:]]+)*)?(${tool_words})([[:space:]]|\$)" "${script}" | grep -vE '^[0-9]+:[[:space:]]*#' || true)
  done <<<"${hits}"
  return 0
}

rule_a
rule_b
rule_c
rule_d
rule_e
rule_f
rule_g
rule_h

exit "${findings}"
