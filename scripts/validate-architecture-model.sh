#!/usr/bin/env bash
# Validate the Structurizr workspace and compare its components with the workspace crates
# (architecture-delivery.md "Architecture Model", gate G27).
#
# Usage: scripts/validate-architecture-model.sh <dsl-file> <crate-list-file>
#
# <crate-list-file> holds one crate per line, the first word is the name (the output of
# `cargo tree --workspace --depth 0 --prefix none`); `-` reads the list from standard input.
# Steps: `validate -workspace` in the Structurizr image; `export -format json` to
# target/reports/structurizr/ (relative to the current directory); require a system-context,
# a container and a component view; read the names of the elements shown in the component view
# from the export (a JSON query run in the Node image) and compare them with the crate list,
# minus xtask, test-support and e2e-tests. Every missing and every extra component is printed.
# Environment: STRUCTURIZR_IMAGE, NODE_IMAGE (both exported by the Makefile), DOCKER (default docker).
# Exit status: 0 consistent; 1 parse error, a view missing, or a component difference;
# 2 usage error or a tool that could not run.
set -euo pipefail

usage() {
  echo "usage: scripts/validate-architecture-model.sh <dsl-file> <crate-list-file>" >&2
}

if [[ $# -eq 1 && ( "$1" == "-h" || "$1" == "--help" ) ]]; then
  usage
  exit 0
fi
if [[ $# -ne 2 ]]; then
  usage
  exit 2
fi

dsl_file="$1"
crate_list="$2"
docker_cmd="${DOCKER:-docker}"

if [[ ! -f "${dsl_file}" ]]; then
  echo "validate-architecture-model: ${dsl_file} is not a file" >&2
  exit 2
fi
if [[ "${crate_list}" != "-" && ! -f "${crate_list}" ]]; then
  echo "validate-architecture-model: ${crate_list} is not a file" >&2
  exit 2
fi
for name in STRUCTURIZR_IMAGE NODE_IMAGE; do
  if [[ -z "${!name:-}" ]]; then
    echo "validate-architecture-model: ${name} is not set (the Makefile exports it from make/tool-versions.mk)" >&2
    exit 2
  fi
done
if ! command -v "${docker_cmd}" > /dev/null 2>&1; then
  echo "validate-architecture-model: ${docker_cmd} is not available" >&2
  exit 2
fi

# Read the crate list before any other command can consume standard input.
if [[ "${crate_list}" == "-" ]]; then
  crates_raw="$(cat)"
else
  crates_raw="$(cat -- "${crate_list}")"
fi

dsl_abs="$(cd "$(dirname "${dsl_file}")" && pwd)/$(basename "${dsl_file}")"
mkdir -p target/reports/structurizr
out_dir="$(cd target/reports/structurizr && pwd)"
rm -f "${out_dir}/workspace.json"
user_args=(--user "$(id -u):$(id -g)")

# The file is mounted read-only and the export goes to a separate directory, so nothing is
# written next to the DSL file (PF-54).
dsl_mount=(-v "${dsl_abs}:/work/workspace.dsl:ro")

if ! "${docker_cmd}" run --rm "${user_args[@]}" "${dsl_mount[@]}" "${STRUCTURIZR_IMAGE}" \
  validate -workspace /work/workspace.dsl; then
  echo "validate-architecture-model: ${dsl_file} does not parse" >&2
  exit 1
fi

if ! "${docker_cmd}" run --rm "${user_args[@]}" "${dsl_mount[@]}" -v "${out_dir}:/out" \
  "${STRUCTURIZR_IMAGE}" export -workspace /work/workspace.dsl -format json -output /out > /dev/null; then
  echo "validate-architecture-model: export of ${dsl_file} failed" >&2
  exit 1
fi
if [[ ! -f "${out_dir}/workspace.json" ]]; then
  echo "validate-architecture-model: the export wrote no workspace.json" >&2
  exit 2
fi

# Prints "view <kind> <count>" for each view kind and "component <name>" for each component
# element shown in a component view.
# shellcheck disable=SC2016 # the JavaScript is passed to node as a literal
query='
const w = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
const views = w.views || {};
for (const kind of ["systemContextViews", "containerViews", "componentViews"]) {
  console.log("view " + kind + " " + (views[kind] || []).length);
}
const components = new Map();
for (const system of (w.model || {}).softwareSystems || []) {
  for (const container of system.containers || []) {
    for (const component of container.components || []) {
      components.set(component.id, component.name);
    }
  }
}
for (const view of views.componentViews || []) {
  for (const element of view.elements || []) {
    if (components.has(element.id)) {
      console.log("component " + components.get(element.id));
    }
  }
}
'
if ! report="$("${docker_cmd}" run --rm "${user_args[@]}" -v "${out_dir}:/data:ro" "${NODE_IMAGE}" \
  node -e "${query}" /data/workspace.json)"; then
  echo "validate-architecture-model: reading the export failed" >&2
  exit 2
fi

status=0
for pair in "systemContextViews:system-context" "containerViews:container" "componentViews:component"; do
  key="${pair%%:*}"
  label="${pair#*:}"
  count="$(awk -v k="${key}" '$1 == "view" && $2 == k { print $3 }' <<< "${report}")"
  if [[ -z "${count}" || "${count}" -lt 1 ]]; then
    echo "missing view: no ${label} view in ${dsl_file}"
    status=1
  fi
done

expected="$(awk 'NF > 0 { print $1 }' <<< "${crates_raw}" \
  | grep -vxF -e xtask -e test-support -e e2e-tests | LC_ALL=C sort -u || true)"
actual="$(awk '$1 == "component" { print $2 }' <<< "${report}" | LC_ALL=C sort -u)"

while IFS= read -r name; do
  [[ -n "${name}" ]] || continue
  echo "missing component: ${name} is a workspace crate but not shown in the component view"
  status=1
done < <(comm -23 <(printf '%s\n' "${expected}") <(printf '%s\n' "${actual}"))
while IFS= read -r name; do
  [[ -n "${name}" ]] || continue
  echo "extra component: ${name} is shown in the component view but is not a workspace crate"
  status=1
done < <(comm -13 <(printf '%s\n' "${expected}") <(printf '%s\n' "${actual}"))

if [[ "${status}" -eq 0 ]]; then
  echo "architecture model OK: $(grep -c . <<< "${actual}") components match the workspace crates"
fi
exit "${status}"
