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

if [[ -n "${explicit}" ]]; then
  bump=(--version "${explicit}")
else
  # 1. Is there anything to release? cocogitto prints a sentence and exits 0 when nothing bumps.
  next="$(cog bump --auto --dry-run 2>&1)" || {
    echo "${next}" >&2
    exit 1
  }
  if [[ ! "${next}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
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
