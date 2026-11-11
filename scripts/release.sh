#!/usr/bin/env bash
# Release flow of release.yml, step 6 (architecture-delivery.md "CI/CD Workflows", DD-11, PF-62):
# version from conventional commits, changelog and manifest through cocogitto, commit
# `chore(release): vX.Y.Z [skip ci]`, tag, push and GitHub release.
#
# Usage: scripts/release.sh [--version <x.y.z>]
# Needs: cog 7.0.0, git, gh (GH_TOKEN in the environment), an `origin` remote and the branch main.
# Exit status: 0 released, or nothing to release; 1 failure.
set -euo pipefail

usage() {
  echo "usage: scripts/release.sh [--version <x.y.z>]" >&2
}

explicit=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      if [[ $# -lt 2 ]]; then
        usage
        exit 1
      fi
      explicit="$2"
      shift 2
      ;;
    --version=*)
      explicit="${1#--version=}"
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 1
      ;;
  esac
done

if [[ -n "${explicit}" && ! "${explicit}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "release: the version must be x.y.z, got: ${explicit}" >&2
  exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$(dirname "${script_dir}")"

# Prints the commits of <range> that carry a breaking change, as cocogitto parses them: `cog changelog` renders
# the range with a template that prints the id of every commit cocogitto marks breaking (a `!` before the colon
# of a conventional subject, or a line that starts with the footer token `BREAKING CHANGE` or `BREAKING-CHANGE`
# followed by `: ` or ` #`; a breaking commit is never omitted from a changelog, whatever its type). Merge commits
# are dropped as `cog bump` drops them.
breaking_commits() {
  local range="$1" template ids
  [[ -n "$(git rev-list --no-merges "${range}")" ]] || return 0
  template="$(mktemp "${TMPDIR:-/tmp}/release-breaking.XXXXXX")"
  printf '%s\n' '{% for commit in commits %}{% if commit.breaking_change %}{{ commit.id }}' \
    '{% endif %}{% endfor %}' >"${template}"
  if ! ids="$(cog changelog "${range}" --template "${template}")"; then
    rm -f "${template}"
    echo "release: cocogitto could not read the commits of ${range}" >&2
    return 1
  fi
  rm -f "${template}"
  [[ -n "${ids}" ]] || return 0
  git rev-list --no-merges "${range}" | grep -F -x -e "${ids}" || true
}

if [[ -n "${explicit}" ]]; then
  bump=(--version "${explicit}")
else
  # 1. Is there anything to release? cocogitto prints a sentence and exits 0 when nothing bumps. cocogitto 7.0.0
  # ignores a breaking change below 1.0.0 (a fix stays a patch, a docs or refactor commit releases nothing), so
  # the script finds breaking changes itself (FR98(a), DD-11), in the range of `cog bump --auto`: from the highest
  # vX.Y.Z tag, or from the oldest commit when there is none, to HEAD.
  next="$(cog bump --auto --dry-run)" || {
    echo "${next}" >&2
    exit 1
  }
  latest="$(git tag --list 'v*' --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1 || true)"
  breaking="$(breaking_commits "${latest:-$(git rev-list HEAD | tail -n 1)}..HEAD")"
  if [[ ! "${next}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ && -z "${breaking}" ]]; then
    echo "${next}"
    exit 0
  fi
  if [[ -z "$(git tag --list 'v*')" ]]; then
    # The first release is the manifest version, whatever the first releasable commit is (DD-11).
    manifest_version="$(awk '
      /^\[/ { in_table = ($0 == "[workspace.package]") }
      in_table && /^version[[:space:]]*=/ { gsub(/^[^"]*"|".*$/, ""); print; exit }
    ' Cargo.toml)"
    if [[ ! "${manifest_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "release: cannot read [workspace.package].version from Cargo.toml" >&2
      exit 1
    fi
    bump=(--version "${manifest_version}")
  elif [[ -n "${breaking}" && "${latest}" == v0.* ]]; then
    # While the version is 0.y.z a breaking change raises the minor number (DD-11).
    bump=(--minor)
  elif [[ -n "${breaking}" ]]; then
    bump=(--major)
  else
    bump=(--auto)
  fi
fi

# 2. Bump: pre-bump hook, changelog, commit and tag.
cog bump "${bump[@]}" --skip-ci

tag="$(git tag --points-at HEAD --list 'v*' | head -n 1)"
if [[ -z "${tag}" ]]; then
  echo "release: cocogitto did not tag HEAD" >&2
  exit 1
fi

# 3. cocogitto names its commit chore(version): ...; amend it and move the tag.
git commit --amend --no-verify -m "chore(release): ${tag} [skip ci]"
git tag -f "${tag}"

# 4. Push. A non-fast-forward rejection fails the job; the next push to main releases both changes.
git push origin HEAD:main
git push origin "${tag}"

# 5. GitHub release.
mkdir -p target
cog changelog --at "${tag}" >target/release-notes.md
gh release create "${tag}" --title "${tag}" --notes-file target/release-notes.md --verify-tag
