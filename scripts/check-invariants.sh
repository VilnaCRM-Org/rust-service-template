#!/usr/bin/env bash
# Repository invariants (gate G31, FR125): pins, toolchain agreement, gate set, repository name, licence,
# blanket suppressions and the execution switch. One rule per letter:
#   (a) workflow hygiene: pinned actions, permissions (declared, none that writes at the top level; a job writes only
#       security-events in the code-scanning jobs codeql, clippy-sarif-upload and code-scanning, or any scope in the
#       release and sync jobs of a workflow that no pull request starts; write-all nowhere), concurrency, timeouts
#       (declared, an integer of at most 45 minutes, 75 for the clean-clone job clean-bootstrap-ci of scheduled.yml);
#       a quoted key ('jobs':, "pull-requests":) is read as the key it names, and a permissions value is read-all,
#       write-all or a mapping whose every value is read, write or none (a tag, anchor or alias is reported)
#   (b) pinned images, tools, features and downloads (Dockerfile, make files, workflows and every shell script): no
#       file has more downloads by URL than checksum verifications (sha256sum, sha512sum or shasum run as a command,
#       or a call of a shell function whose body runs one; comments and image digests are no evidence), and an ADD
#       of a URL in the Dockerfile carries --checksum=
#   (c) one toolchain version in rust-toolchain.toml, the builder image tag and rust-version
#   (d) the gate set of `make ci-list` equals the gate set of the pull-request workflows (and every workflow runs
#       only gate and CI-only targets); Bats groups; required checks
#   (e) the repository name occurs only where DD-23 allows it
#   (f) the licence identifier is CC0-1.0 everywhere it is stated
#   (g) no `allow` attribute, no `expect` in a crate root, no lint group in an `allow` or `expect` (also inside a
#       `cfg_attr`)
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

# True when the workflow file (second argument) has a trigger of the event (first argument): `on: <event>`,
# `on: [push, <event>]`, an `<event>:` key or a `- <event>` list entry. A quoted key or entry ('on':,
# "pull_request":, - 'pull_request') is the same key.
has_trigger() {
  local q="[\"']?"
  grep -qE "^[[:space:]]*(-[[:space:]]*)?${q}$1${q}[[:space:]]*(:|\$)|^${q}on${q}:[[:space:]]*\\[?.*\\b$1\\b" "$2"
}

# True when the workflow has a pull_request trigger.
has_pull_request_trigger() {
  has_trigger pull_request "$1"
}

# True when a pull request starts the workflow: a pull_request or a pull_request_target trigger (NFR14).
runs_on_pull_requests() {
  has_trigger pull_request "$1" || has_trigger pull_request_target "$1"
}

# ---------------------------------------------------------------------------------------------------------------
# (a) Workflows
# ---------------------------------------------------------------------------------------------------------------
# Job-level write scopes (NFR14): `security-events: write` only in the code-scanning jobs, any other write scope
# only in the release and sync jobs of a workflow that no pull request starts; `write-all` names no scope and is
# refused in every job. Job timeouts (NFR39): an integer literal of at most 45 minutes, 75 for the clean-clone job
# clean-bootstrap-ci of scheduled.yml. A quoted key at the start of a line ('jobs':, "lint":, 'timeout-minutes':,
# - 'uses':, 'pull-requests':) is read as the key it names, so quoting a key hides nothing; YAML and prettier both
# accept that form. A permissions value, of the workflow or of a job, is read in full and fails closed (see
# perm_start below).
check_workflow_hygiene() {
  local file=$1 pull_requests=0
  runs_on_pull_requests "${file}" && pull_requests=1
  awk -v exempt_list='release sync' -v scanning_list='codeql clippy-sarif-upload code-scanning' \
    -v pull_requests="${pull_requests}" '
    function out(msg) { print "(a) " FILENAME ": " msg }
    # The line with the quotes (single or double) of a key at its start removed: "lint": reads as lint:.
    function plain_key(line,   key) {
      if (!match(line, /^[[:space:]]*(-[[:space:]]+)?["\047][A-Za-z0-9_-]+["\047][[:space:]]*:/)) return line
      key = substr(line, 1, RLENGTH)
      gsub(/["\047]/, "", key)
      return key substr(line, RLENGTH + 1)
    }
    function unquoted(text) { gsub(/["\047]/, "", text); return text }
    function indent(s) { match(s, /^ */); return RLENGTH }
    # The text of a line without the white space around it and without its comment (a # after white space).
    function bare(text) {
      sub(/^[[:space:]]+/, "", text)
      if (text ~ /^#/) return ""
      sub(/[[:space:]]+#.*$/, "", text)
      sub(/[[:space:]]+$/, "", text)
      return text
    }
    function flush_job() {
      if (job != "") {
        if (!has_timeout) out("job " job " has no timeout-minutes")
        if (has_perm && !perm_ok && !(job in exempt)) out("job " job " has a permissions block without contents: read")
      }
      job = ""
    }
    # One write scope of the job: allowed for security-events in a code-scanning job and for any scope in the
    # release and sync jobs of a workflow that no pull request starts.
    function grant(scope) {
      if (scope == "security-events" && (job in scanning)) return
      if (!pull_requests && (job in exempt)) return
      out("job " job " grants " scope ": write")
    }
    # The value of a permissions key, read in full and failing closed: read-all, write-all, or a mapping (a block or
    # a flow mapping, also on the lines after the key) whose every value is read, write or none, quotes and comments
    # removed. A tag, an anchor or an alias (!!str write, &w write, *w), a folded or literal block scalar and any
    # other spelling hides the value from this rule and is reported. p_top is 1 for the workflow, 0 for a job.
    function subject() { return p_top ? "the workflow" : "job " job }
    function perm_start(rest, top) {
      p_on = 1; p_top = top; p_base = top ? 0 : 4; p_flow = ""; p_member = ""; p_indent = 0
      rest = bare(rest)
      if (rest == "") p_mode = "open"
      else if (rest ~ /^\{/) { p_mode = "flow"; p_flow = rest }
      else { p_mode = "scalar"; perm_scalar(unquoted(rest)) }
    }
    # A line deeper than the key: a flow mapping takes every such line (prettier puts each brace and each member on
    # a line of its own when the mapping is long); in a block mapping a line at the indentation of the first key
    # starts an entry and a deeper line continues the value of the entry before it (>- and the like).
    function perm_line(line,   n, text) {
      n = indent(line); text = bare(line)
      if (text == "" || p_mode == "scalar") return
      if (p_mode == "open" && text ~ /^\{/) { p_mode = "flow"; p_flow = text; return }
      if (p_mode == "open") { p_mode = "block"; p_indent = n; p_member = text; return }
      if (p_mode == "flow") { p_flow = p_flow " " text; return }
      if (n > p_indent) { p_member = p_member " " text; return }
      perm_member(p_member); p_member = text; p_indent = n
    }
    function perm_end(   n, i, parts) {
      if (!p_on) return
      p_on = 0
      if (p_mode == "block") perm_member(p_member)
      if (p_mode != "flow") return
      sub(/^\{/, "", p_flow); sub(/\}$/, "", p_flow)
      n = split(p_flow, parts, ",")
      for (i = 1; i <= n; i++) if (parts[i] !~ /^[[:space:]]*$/) perm_member(parts[i])
    }
    function perm_scalar(value) {
      if (value == "read-all" || (value == "write-all" && p_top)) return
      if (value == "write-all") out("job " job " grants write-all; a job names each scope it writes")
      else out(subject() " has permissions: " value ", but only read-all, write-all or a mapping of scopes is read")
    }
    # One <scope>: <value> entry. A write of the workflow is reported line by line by the top-level check.
    function perm_member(text,   scope, value) {
      text = unquoted(text)
      sub(/^[[:space:]]+/, "", text); sub(/[[:space:]]+$/, "", text)
      if (!match(text, /^[A-Za-z][A-Za-z-]*[[:space:]]*:([[:space:]]|$)/)) {
        out(subject() " has the permissions entry " text ", which is no <scope>: <value> pair"); return
      }
      scope = text; sub(/[[:space:]]*:.*$/, "", scope)
      value = substr(text, RLENGTH + 1); sub(/^[[:space:]]+/, "", value)
      if (value == "") out(subject() " gives " scope " no value; a scope takes read, write or none")
      else if (value == "write" && !p_top) grant(scope)
      else if (value == "read" && scope == "contents" && !p_top) perm_ok = 1
      else if (value != "read" && value != "write" && value != "none")
        out(subject() " gives " scope " the value " value "; a scope takes read, write or none")
    }
    # The timeout of the job: an integer literal of at most 45 minutes, 75 for the clean-clone job.
    function timeout_value(text,   limit) {
      sub(/^    timeout-minutes:[[:space:]]*/, "", text)
      sub(/[[:space:]]*#.*$/, "", text)
      sub(/[[:space:]]+$/, "", text)
      limit = (job == "clean-bootstrap-ci" && FILENAME ~ /(^|\/)scheduled\.yml$/) ? 75 : 45
      if (text !~ /^[0-9]+$/) out("job " job " has timeout-minutes " text ", which is not an integer literal (limit " limit " of NFR39)")
      else if (text + 0 > limit) out("job " job " has timeout-minutes " text ", above the limit of " limit " of NFR39")
    }
    BEGIN {
      n = split(exempt_list, e, " ")
      for (i = 1; i <= n; i++) exempt[e[i]] = 1
      n = split(scanning_list, e, " ")
      for (i = 1; i <= n; i++) scanning[e[i]] = 1
    }
    { $0 = plain_key($0) }
    /^[[:space:]]*#/ { next }
    # The lines of the value of a permissions key: deeper than the key. A job-level value line is nothing else.
    p_on && $0 !~ /^[[:space:]]*$/ {
      if (indent($0) > p_base) { perm_line($0); if (!p_top) next }
      else perm_end()
    }
    /^permissions:/ {
      top_perm = 1
      v = $0
      sub(/^permissions:/, "", v)
      perm_start(v, 1)
    }
    /^[^[:space:]#]/ { in_top_perm = ($0 ~ /^permissions:/) }
    in_top_perm {
      v = $0
      sub(/[[:space:]]*#.*$/, "", v)
      if (v ~ /write/) out("line " NR ": the top-level permissions block grants write access; write permissions belong to the job that needs them")
    }
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
      has_timeout = 0; has_perm = 0; perm_ok = 0
      next
    }
    in_jobs && job != "" {
      if ($0 ~ /^    timeout-minutes:/) { has_timeout = 1; timeout_value($0) }
      # The value of the key ends at the next line of the indentation of the key (the next key of the job, such as
      # steps:), so the `with:` inputs of a step, such as permission-contents: write of create-github-app-token,
      # are no scopes of the job token.
      if ($0 ~ /^    permissions:/) {
        has_perm = 1
        v = $0
        sub(/^    permissions:/, "", v)
        perm_start(v, 0)
      }
    }
    END {
      perm_end()
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
    # build: it needs a version tag and a digest like every other image. Parser directives (`# name=value`,
    # for example `# escape=` or `# check=`) stand at the top in any order, before the first line that is not
    # a directive; a comment, an empty line or an instruction ends them.
    if [[ "${in_directives}" == 1 ]]; then
      if [[ "${line}" =~ ^#[[:space:]]*([A-Za-z][A-Za-z0-9_-]*)[[:space:]]*=[[:space:]]*([^[:space:]]*) ]]; then
        if [[ "$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')" == syntax ]]; then
          check_image_ref "${file}:${number}" "${BASH_REMATCH[2]}"
        fi
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

# Every shell script of the tree: the files below scripts/, tests/Load/ and .githooks/ and every other `*.sh`,
# `*.bash` and `*.bats` file, without the Bats fixtures (planted violations) and the ignored tool and state
# directories.
shell_scripts() {
  find . \( -name target -o -name node_modules -o -name .git -o -name .tools -o -name '_bmad*' -o -name .ralph \
    -o -path ./tests/CLI/bats/fixtures \) -prune -o -type f \( -name '*.sh' -o -name '*.bash' -o -name '*.bats' \
    -o -path './scripts/*' -o -path './tests/Load/*' -o -path './.githooks/*' \) -print | sed 's|^\./||' | LC_ALL=C sort
  return 0
}

# Words of the download commands and of the checksum commands. The patterns are assembled from them, so that no
# line of this script reads as a download.
fetch_words='curl|wget'
verify_words='sha256sum|sha512sum|shasum'
download_re="\\b(${fetch_words})\\b[^#]*(https?://|--output|--remote-name|[[:space:]]-[A-Za-z]*[oOL][A-Za-z]*[[:space:]]|--location|--fail)"

# Number of download lines of a file: a curl or wget line, outside comments, with a URL or a download option.
download_count() {
  local file=$1
  # A request whose only address is the loopback interface (a probe of the service under test, as the Bats
  # files of the lifecycle targets send) fetches no file from elsewhere and is not a download. A loopback URL
  # is the host localhost, 127.0.0.1 or [::1], an optional port, an optional path without `@`, then a quote,
  # white space or the end of the line (so `http://localhost@host/` names a remote host). A line is a probe and
  # left out only when, once its loopback URLs are removed, it holds exactly one curl or wget, no other URL, no
  # `$` expansion and no backtick (an address computed elsewhere), no dotted word (a host, an IPv4 address or a
  # file name), no word with a `/` that starts like a host name or a bracketed IPv6 address, also after `=`
  # (`intranet/tool`, `'[2001:db8::1]/tool'`, `--url=intranet/tool`: an address without a scheme;
  # `--input-file=lists/tools`: a file of addresses), no option
  # that names the address or sends the request elsewhere (`--url`, `--resolve`, `--connect-to`, `-x`,
  # `--proxy*`, `--preproxy`, `--socks*`) or proxy variable (`https_proxy=`), and no continuation backslash. A
  # probe may stand in a command substitution that starts with it (`status=$(curl -s -o /dev/null -w
  # '%{http_code}' http://...)`); the backtick form is not read as a probe. The decision reads that copy; every
  # other line goes unchanged to the download pattern, so a loopback proxy still counts as the URL of the
  # command. Known limits: an expansion in the port position of a loopback URL (`http://127.0.0.1:${APP_PORT}/`)
  # is trusted; a bare word without a dot or a `/` (a one-label host such as `intranet`) cannot be told from an
  # option argument (`--max-time 10`, `--noproxy '*'`, which the probes of the tree use) and is trusted; a proxy
  # exported on an earlier line is not seen.
  grep -vE '^[[:space:]]*#' "${file}" \
    | awk '{
        rest = $0
        n = gsub(/[A-Za-z]+:\/\/(localhost|127\.0\.0\.1|\[::1\])(:[^\/?@[:space:]"\047]*)?([\/?][^@[:space:]"\047]*)?(["\047]|[[:space:]]|$)/, " ", rest)
        gsub(/\$\(curl/, " curl", rest)
        gsub(/\$\(wget/, " wget", rest)
        probe = n > 0 && rest !~ /:\/\// && rest !~ /\$/ && rest !~ /`/ && rest !~ /\\[[:space:]]*$/ && rest !~ /[A-Za-z0-9]\.[A-Za-z0-9]/
        if (probe && rest ~ /(^|[[:space:]=])["\047]?([A-Za-z0-9_][A-Za-z0-9_.:@%+~-]*\/|\[[0-9A-Fa-f.]*:[0-9A-Fa-f:.]*\])/) probe = 0
        if (probe && rest ~ /(^|[[:space:]])(--(resolve|connect-to|proxy|preproxy|socks|url)|-[A-Za-z]*x)/) probe = 0
        if (probe && tolower(rest) ~ /(^|[^a-z0-9_])(https?|all|ftp)_proxy=/) probe = 0
        if (probe && gsub(/(^|[^A-Za-z0-9_-])(curl|wget)([^A-Za-z0-9_-]|$)/, "&", rest) != 1) probe = 0
        if (!probe) print
      }' \
    | grep -cE "${download_re}" || true
  return 0
}

# Number of checksum verifications of a file. A verification is a run of sha256sum, sha512sum or shasum, or a call
# of a shell function whose body runs one (sha256_of of scripts/install-tools.sh), in the position of a command:
# at the start of a line or after `|`, `;`, `&`, `(`, `{`, `!`, `@`, a backtick, `$(`, `then`, `do`, `else`, `if`,
# `elif`, `while`, `until`, `exec`, `time`, `sudo`, `RUN` or `run:`. Comments and image digests (`@sha256:...`) are
# no evidence, and neither is a lookup such as `command -v sha256sum` or a word in a message. Each call of such a
# function counts once and the runs inside its body do not; a function the file never calls counts once (a library
# function that a caller uses). Known limits: a command behind another prefix (`xargs sha256sum`, `env X=1
# sha256sum`) is not counted, and a comment sign after white space ends the line even inside quotes, so both make
# the rule stricter, never weaker.
verification_count() {
  awk -v base="${verify_words}" '
    function runs(s, words) {
      return s ~ ("(^|[;&|({!@`]|[$][(]|(^|[^A-Za-z0-9_])(then|do|else|if|elif|while|until|exec|time|sudo|RUN|run:))[[:space:]]*(" words ")([^A-Za-z0-9_.-]|$)")
    }
    {
      s = $0
      if (s ~ /^[[:space:]]*#/) s = ""
      sub(/(^|[[:space:]])#.*$/, "", s)
      gsub(/@sha(256|512):[0-9A-Fa-f]+/, "", s)
      text[NR] = s
    }
    END {
      nf = 0
      for (i = 1; i <= NR; i++) {
        s = text[i]
        if (s !~ /^[[:space:]]*(function[[:space:]]+)?[A-Za-z_][A-Za-z0-9_-]*[[:space:]]*\(\)/ && s !~ /^[[:space:]]*function[[:space:]]+[A-Za-z_]/) continue
        name = s
        sub(/^[[:space:]]*(function[[:space:]]+)?/, "", name)
        sub(/[^A-Za-z0-9_-].*$/, "", name)
        indent = s
        sub(/[^[:space:]].*$/, "", indent)
        # The body ends on the same line when its braces balance there, otherwise at the first closing brace at the
        # indentation of the definition.
        last = i
        opens = gsub(/[{]/, "{", s)
        closes = gsub(/[}]/, "}", s)
        if (opens == 0 || opens != closes) {
          for (j = i + 1; j <= NR; j++) if (text[j] ~ ("^" indent "[}]")) { last = j; break }
        }
        verifier = 0
        for (j = i; j <= last; j++) {
          s = text[j]
          if (j == i && !sub(/^[^{]*[{]/, "", s)) s = ""
          if (runs(s, base)) verifier = 1
        }
        if (!verifier) continue
        nf++
        fname[nf] = name
        for (j = i; j <= last; j++) body[j] = nf
      }
      words = base
      for (k = 1; k <= nf; k++) words = words "|" fname[k]
      count = 0
      for (i = 1; i <= NR; i++) {
        if (body[i] == 0 && runs(text[i], words)) count++
        for (k = 1; k <= nf; k++) if (body[i] != k && runs(text[i], fname[k])) called[k] = 1
      }
      for (k = 1; k <= nf; k++) if (!called[k]) count++
      print count
    }
  ' "$1"
  return 0
}

# An ADD of a URL in the Dockerfile is a download that its own --checksum= verifies: a sha256, sha384 or sha512
# digest. Continued lines are joined, comment lines are left out.
check_dockerfile_add() {
  local file=$1 number text word url checksum digest='^(sha256:[0-9a-f]{64}|sha384:[0-9a-f]{96}|sha512:[0-9a-f]{128})$'
  local -a words
  while IFS=$'\t' read -r number text; do
    url=''
    checksum=''
    read -r -a words <<<"${text}"
    for word in "${words[@]}"; do
      word=${word//[\"\'\[\],]/}
      case "${word}" in
        --checksum=*) checksum=${word#--checksum=} ;;
        http://* | https://*) [[ -n "${url}" ]] || url=${word} ;;
        *) ;;
      esac
    done
    [[ -n "${url}" ]] || continue
    if [[ -z "${checksum}" ]]; then
      report b "${file}:${number}: ADD downloads ${url} without --checksum="
    elif [[ ! "${checksum}" =~ ${digest} ]]; then
      report b "${file}:${number}: ADD downloads ${url} with --checksum=${checksum}, which is not a sha256, sha384 or sha512 digest"
    fi
  done < <(awk '
    /^[[:space:]]*#/ { next }
    {
      line = $0
      if (!cont) { start = NR; logical = "" }
      cont = (line ~ /\\[[:space:]]*$/)
      if (cont) sub(/\\[[:space:]]*$/, " ", line)
      logical = logical line
      if (!cont && logical ~ /^[[:space:]]*[Aa][Dd][Dd][[:space:]]/) print start "\t" logical
    }
  ' "${file}")
  return 0
}

# A file whose download lines outnumber its checksum verifications downloads a file by URL without a checksum.
check_downloads() {
  local file downloads verifications
  [[ -f Dockerfile ]] && check_dockerfile_add Dockerfile
  for file in Dockerfile "${make_files[@]+"${make_files[@]}"}" "${workflows[@]+"${workflows[@]}"}" $(shell_scripts); do
    [[ -f "${file}" ]] || continue
    downloads=$(download_count "${file}")
    ((downloads > 0)) || continue
    verifications=$(verification_count "${file}")
    if ((downloads > verifications)); then
      report b "${file}: a file is downloaded by URL without a checksum"
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
  local gates target ran pr_ran file
  local -a pr_workflows=()
  if ! gates=$(make --no-print-directory -s -C "${root}" ci-list 2>/dev/null); then
    report d 'make ci-list failed: the gate targets cannot be read'
    return 0
  fi
  if ((${#workflows[@]} == 0)); then
    report d 'no workflow files in .github/workflows: no workflow runs any gate target of make ci-list'
    return 0
  fi
  for file in "${workflows[@]}"; do
    has_pull_request_trigger "${file}" && pr_workflows+=("${file}")
  done
  # FR125(d) compares make ci with the pull-request workflows: a gate that only a scheduled or release workflow
  # runs does not protect a pull request.
  pr_ran=''
  if ((${#pr_workflows[@]} > 0)); then
    pr_ran=$(workflow_make_targets "${pr_workflows[@]}")
  fi
  for target in ${gates}; do
    [[ "${indirect_targets}" == *" ${target} "* ]] && continue
    if ! grep -qxF -- "${target}" <<<"${pr_ran}"; then
      report d "gate target ${target} of make ci-list is run by no pull-request workflow"
    fi
  done
  # Every workflow, whatever its trigger, runs only gate targets and the CI-only targets.
  ran=$(workflow_make_targets "${workflows[@]}")
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
    has_pull_request_trigger "${file}" || continue
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
    # The checks of one suppression of the given kind.
    function judge() {
      if (kind == "allow") out("#[allow or #![allow is not permitted")
      if (kind == "expect" && inner && root) out("#![expect( in a crate root is not permitted")
    }
    FNR == 1 { collecting = 0; root = is_root(FILENAME) }
    /^[[:space:]]*\/\// { next }
    {
      line = $0
      if (!collecting && line ~ /#!?\[[[:space:]]*(allow|expect|cfg_attr)([^A-Za-z0-9_]|$)/) {
        start = FNR
        inner = (line ~ /#!\[/)
        # A cfg_attr applies its attributes under a condition: the allow or expect inside it is read once
        # the attribute is complete.
        conditional = (line ~ /#!?\[[[:space:]]*cfg_attr/)
        kind = ""
        if (!conditional) {
          kind = (line ~ /#!?\[[[:space:]]*allow/) ? "allow" : "expect"
          judge()
        }
        collecting = 1
        text = ""
      }
      if (collecting) {
        text = text " " line
        if (line ~ /\)[[:space:]]*\]/ || line ~ /^[[:space:]]*#!?\[[^(]*\]/) {
          bare = strip_strings(text)
          if (conditional) {
            if (bare ~ /(^|[^A-Za-z0-9_])allow[[:space:]]*\(/) kind = "allow"
            else if (bare ~ /(^|[^A-Za-z0-9_])expect[[:space:]]*\(/) kind = "expect"
            if (kind != "") judge()
          }
          if (kind != "" && bare ~ group_re) out("an " kind " names a lint group")
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
