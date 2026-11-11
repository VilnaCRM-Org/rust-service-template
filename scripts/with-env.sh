#!/usr/bin/env bash
# Export the NAME=value pairs of the given env files, in order, then run a command.
#
# Usage: with-env.sh <env-file>... -- <command>...
#
# A later file overrides an earlier one. A variable that the caller has already set is never changed, by
# any file. `${NAME}` references in a value are expanded from the environment as it is at that point.
# Exit status: the command's; 2 when a file is missing, the separator is absent or no command follows it.
set -euo pipefail

usage() {
  echo "usage: with-env.sh <env-file>... -- <command>..." >&2
  exit 2
}

# Expand every ${NAME} of $1 once, left to right; an unset variable expands to nothing.
expand() {
  local rest=$1 out='' ref token
  while [[ $rest =~ \$\{([A-Za-z_][A-Za-z0-9_]*)\} ]]; do
    token=${BASH_REMATCH[0]}
    ref=${BASH_REMATCH[1]}
    out+=${rest%%"$token"*}${!ref-}
    rest=${rest#*"$token"}
  done
  printf '%s' "$out$rest"
}

files=()
while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
  files+=("$1")
  shift
done
[ "$#" -gt 0 ] || { echo "with-env.sh: the separator '--' is missing" >&2; usage; }
shift
[ "${#files[@]}" -gt 0 ] || { echo "with-env.sh: no env file given" >&2; usage; }
[ "$#" -gt 0 ] || { echo "with-env.sh: no command given" >&2; usage; }

for file in "${files[@]}"; do
  [ -f "$file" ] || { echo "with-env.sh: env file not found: $file" >&2; exit 2; }
done

# Names the caller has set: no file may change them.
declare -A caller=()
while IFS= read -r name; do
  caller[$name]=1
done < <(compgen -e)

for file in "${files[@]}"; do
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case $line in '' | '#'*) continue ;; esac
    name=${line%%=*}
    [[ $name =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { echo "with-env.sh: invalid line in $file: $line" >&2; exit 2; }
    [ -z "${caller[$name]+set}" ] || continue
    export "$name=$(expand "${line#*=}")"
  done <"$file"
done

exec "$@"
