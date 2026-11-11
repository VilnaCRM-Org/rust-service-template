#!/usr/bin/env bats
# Negative tests of the repository gates: one test per linter of G23 (lint-repo), and the Make-level tests of the
# documentation-drift gate G26, the architecture-model gate G27 and the invariants gate G31. There is no passing-run
# test of a gate: the passing run of lint-repo is the gate itself (DD-02, DD-07). The template-sync check of the
# synchronised Rust files has no Make target, so its passing run is a test here, next to its negative
# (architecture-delivery.md "CLI Tests (Bats)", file make_repository.bats). The same holds for the check of the home
# directory of the development stage of the Dockerfile (FR95).
#
# A violation is planted under a name that the linter picks up (the fixtures keep the extension .txt and are excluded
# from every linter) and is removed by restore_planted, which the teardown calls.

bats_require_minimum_version 1.8.0
load test_helper

# bats file_tags=repository

setup() {
  _common_setup
  fixtures="${REPO_ROOT}/tests/CLI/bats/fixtures"
  tmp="$(mktemp -d)"
  # The misspelt word is assembled so that this file itself passes the spelling check.
  misspelt="reci""eve"
}

teardown() {
  restore_planted
  [[ -z "${tmp:-}" ]] || rm -rf -- "${tmp}"
}

# --- G23: one test per linter -------------------------------------------------------------------------------

@test "lint-actions: a workflow with a syntax error fails with the finding of actionlint" {
  require_docker
  plant_new .github/workflows/planted_syntax_error.yml "${fixtures}/workflow_syntax_error.yml.txt"
  run make --no-print-directory lint-actions
  assert_failure
  assert_output --partial 'planted_syntax_error.yml'
  assert_output --regexp '\[(syntax-check|shell-name|expression)\]'
}

@test "lint-actions: a workflow with an unpinned action fails with the finding of zizmor" {
  require_docker
  require_command zizmor
  plant_new .github/workflows/planted_unpinned_action.yml "${fixtures}/workflow_unpinned_action.yml.txt"
  run make --no-print-directory lint-actions
  assert_failure
  assert_output --partial 'unpinned-uses'
  assert_output --partial 'planted_unpinned_action.yml'
}

@test "lint-yaml: a YAML file with a duplicate key fails with the finding of yamllint" {
  require_docker
  plant_new planted_duplicate_key.yml "${fixtures}/duplicate_key.yml.txt"
  run make --no-print-directory lint-yaml
  assert_failure
  assert_output --partial 'planted_duplicate_key.yml'
  assert_output --partial 'duplication of key'
}

@test "lint-markdown: a Markdown file with a skipped heading level fails with the finding of markdownlint" {
  require_docker
  plant_new planted_skipped_heading.md "${fixtures}/skipped_heading.md.txt"
  run make --no-print-directory lint-markdown
  assert_failure
  assert_output --partial 'planted_skipped_heading.md'
  assert_output --partial 'MD001'
}

@test "lint-shell: a script with an unquoted expansion fails with the finding of shellcheck" {
  require_docker
  plant_new scripts/planted_unquoted_expansion.sh "${fixtures}/unquoted_expansion.sh.txt"
  run make --no-print-directory lint-shell
  assert_failure
  assert_output --partial 'planted_unquoted_expansion.sh'
  assert_output --partial 'SC2086'
}

@test "lint-docker: a Dockerfile with the tag latest fails with the finding of hadolint" {
  require_docker
  run make --no-print-directory lint-docker DOCKERFILES=tests/CLI/bats/fixtures/Dockerfile.latest.txt
  assert_failure
  assert_output --partial 'DL3007'
}

@test "lint-toml: an unformatted TOML file fails with the finding of taplo" {
  require_command taplo
  plant_new planted_unformatted.toml "${fixtures}/unformatted.toml.txt"
  run make --no-print-directory lint-toml
  assert_failure
  assert_output --regexp 'not properly formatted path="[^"]*/planted_unformatted\.toml"'
}

@test "lint-spelling: a misspelt word fails with the finding of typos" {
  require_command typos
  plant_new planted_misspelt.md "${fixtures}/misspelt.md.txt"
  run make --no-print-directory lint-spelling
  assert_failure
  assert_output --partial "${misspelt}"
  assert_output --partial 'planted_misspelt.md'
}

@test "lint-spelling: a misspelt file name fails with the finding of typos" {
  require_command typos
  plant_new "planted_${misspelt}_name.md" "${fixtures}/skipped_heading.md.txt"
  run make --no-print-directory lint-spelling
  assert_failure
  assert_output --partial "${misspelt}"
  assert_output --partial "planted_${misspelt}_name.md"
}

@test "lint-spelling: a misspelt workflow name fails with the finding of typos" {
  require_command typos
  printf 'name: Planted %s\non: push\n' "${misspelt}" >"${tmp}/workflow.yml"
  plant_new .github/workflows/planted_spelling.yml "${tmp}/workflow.yml"
  run make --no-print-directory lint-spelling
  assert_failure
  assert_output --partial "${misspelt}"
  assert_output --partial '.github/workflows/planted_spelling.yml'
}

@test "lint-spelling: a misspelt file name in a hidden directory fails with the finding of typos" {
  require_command typos
  plant_new ".github/planted_${misspelt}_name.md" "${fixtures}/skipped_heading.md.txt"
  run make --no-print-directory lint-spelling
  assert_failure
  assert_output --partial "${misspelt}"
  assert_output --partial ".github/planted_${misspelt}_name.md"
}

@test "lint-prettier: an unformatted JSON file fails with the finding of Prettier" {
  require_docker
  plant_new planted_unformatted.json "${fixtures}/unformatted.json.txt"
  run make --no-print-directory lint-prettier
  assert_failure
  assert_output --partial 'planted_unformatted.json'
  assert_output --partial 'Code style issues found'
}

# --- Template sync: synchronised tests stay free of the example context -------------------------------------

# The Rust files a commit would contain (tracked, or untracked and not ignored by git) that name the example
# context or build the `Adapters` literal and that the template sync does not ignore. A sync restores the
# template's copy of such a file, so it must not depend on what a service changes (FR100).
synchronised_rust_files_naming_the_example() {
  local -a naming=()
  mapfile -t naming < <(git ls-files -z --cached --others --exclude-standard -- '*.rs' |
    xargs -0 grep -l -s -E 'example_api_resources|ExampleApiResource|some_module|Adapters \{' -- | sort -u)
  ((${#naming[@]} > 0)) || return 0
  comm -23 <(printf '%s\n' "${naming[@]}") \
    <(git ls-files --cached --others --ignored --exclude-from=.templatesyncignore -- "${naming[@]}" | sort -u)
}

@test "no synchronised Rust file names the example context or builds the Adapters literal" {
  run synchronised_rust_files_naming_the_example
  assert_success
  assert_output ''
}

@test "a planted synchronised test that names the example table is reported" {
  printf 'const TABLE: &str = "example_api_resources";\n' >"${tmp}/planted.rs"
  plant_new crates/shared/infrastructure/tests/integration/planted_example_table.rs "${tmp}/planted.rs"
  run synchronised_rust_files_naming_the_example
  assert_success
  assert_output 'crates/shared/infrastructure/tests/integration/planted_example_table.rs'
}

# --- FR95: the home directory of the development stage ------------------------------------------------------

# Reports a Dockerfile ($1) whose stage $2, with the stages it is built from, leaves the directory that HOME points to
# world-writable with the sticky bit. The common-utils feature of .devcontainer/ gives the user a .bashrc in that
# directory and then appends to it as root, which the kernel setting fs.protected_regular (set on the hosted runners)
# refuses in a sticky world-writable directory of another owner. The numeric modes of the chmod commands are applied
# in order; a symbolic mode on HOME is reported, because it is not evaluated. Exit status 0 nothing to report, 1 a
# finding, 2 the stage or its HOME is missing.
dev_home_finding() {
  awk -v want="$2" '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    function bare(p) { gsub(/^["\047]|["\047]$/, "", p); if (p != "/") sub(/\/+$/, "", p); return p }
    function handle(line, at,    n, i, k, ins, img, p, last) {
      n = split(trim(line), w, /[[:space:]]+/)
      ins = toupper(w[1])
      if (ins == "FROM") {
        i = 2
        while (i <= n && w[i] ~ /^--/) i++
        img = w[i]
        cur = (i + 2 <= n && toupper(w[i + 1]) == "AS") ? w[i + 2] : img
        parent[cur] = ((img in known) && img != cur) ? img : ""
        known[cur] = 1
        return
      }
      if (cur == "") return
      if (ins == "ENV") {
        if (n >= 3 && w[2] == "HOME") home[cur] = bare(w[3])
        for (i = 2; i <= n; i++) if (w[i] ~ /^HOME=/) home[cur] = bare(substr(w[i], 6))
        return
      }
      if (ins != "RUN") return
      for (i = 2; i < n; i++) {
        if (w[i] != "chmod") continue
        k = i + 1
        while (k <= n && (w[k] ~ /^--/ || w[k] ~ /^-[RcfvHLP]+$/)) k++
        for (p = k + 1; p <= n; p++) {
          if (w[p] == "&&" || w[p] == "||" || w[p] == ";" || w[p] == "|") break
          last = (w[p] ~ /;$/)
          ops++
          ostage[ops] = cur; omode[ops] = w[k]; oline[ops] = at
          opath[ops] = w[p]
          sub(/;$/, "", opath[ops])
          opath[ops] = bare(opath[ops])
          if (last) break
        }
      }
    }
    /^[[:space:]]*#/ { next }
    {
      if (buf == "") start = NR
      line = $0
      if (line ~ /\\[[:space:]]*$/) { sub(/\\[[:space:]]*$/, "", line); buf = buf line " "; next }
      handle(buf line, start)
      buf = ""
    }
    END {
      if (buf != "") handle(buf, start)
      if (!(want in known)) { printf "stage %s not found in %s\n", want, FILENAME; exit 2 }
      m = 0
      for (s = want; s != "" && m < 100; s = parent[s]) { m++; chain[m] = s; inchain[s] = 1 }
      h = ""
      for (i = m; i >= 1; i--) if (chain[i] in home) h = home[chain[i]]
      if (h == "") { printf "stage %s of %s sets no HOME\n", want, FILENAME; exit 2 }
      bad = 0
      for (i = 1; i <= ops; i++) {
        if (!(ostage[i] in inchain)) continue
        if (opath[i] != h && opath[i] != "$HOME" && opath[i] != "${HOME}") continue
        if (omode[i] !~ /^[0-7]+$/) {
          printf "%s:%d: stage %s changes HOME %s with the symbolic mode %s\n", FILENAME, oline[i], ostage[i], h, omode[i]
          exit 1
        }
        d = substr(omode[i], length(omode[i]), 1) + 0
        sticky = length(omode[i]) >= 4 && (substr(omode[i], length(omode[i]) - 3, 1) + 0) % 2 == 1
        bad = sticky && (d == 2 || d == 3 || d == 6 || d == 7)
        at = oline[i]; mode = omode[i]; stage = ostage[i]
      }
      if (bad) {
        printf "%s:%d: stage %s gives HOME %s the mode %s: world-writable with the sticky bit\n", FILENAME, at, stage, h, mode
        exit 1
      }
    }
  ' "$1"
}

# The stage of the Dockerfile that .devcontainer/devcontainer.json builds.
devcontainer_target() {
  sed -n 's/.*"target"[[:space:]]*:[[:space:]]*"\([A-Za-z0-9_.-]*\)".*/\1/p' .devcontainer/devcontainer.json
}

# A Dockerfile in ${tmp}: stage base runs $1, stage dev (built from base) runs $2 and sets HOME, stage prod runs $3.
planted_dockerfile() {
  printf 'FROM debian:13 AS base\nRUN %s\n\nFROM base AS dev\nRUN mkdir -p /cargo /home/dev \\\n && %s\nENV LANG=C.UTF-8 \\\n    HOME=/home/dev\n\nFROM base AS prod\nRUN %s\n' \
    "$1" "$2" "$3" >"${tmp}/Dockerfile"
}

@test "the development stage does not leave its home directory world-writable with the sticky bit" {
  stage="$(devcontainer_target)"
  [[ -n "${stage}" ]]
  run dev_home_finding Dockerfile "${stage}"
  assert_success
  assert_output ''
}

@test "a world-writable home directory with the sticky bit in the development stage is reported" {
  planted_dockerfile true 'chmod 1777 /cargo /home/dev /cargo-target' true
  run dev_home_finding "${tmp}/Dockerfile" dev
  assert_failure 1
  assert_output "${tmp}/Dockerfile:5: stage dev gives HOME /home/dev the mode 1777: world-writable with the sticky bit"

  planted_dockerfile 'mkdir -p /home/dev && chmod 3777 /home/dev/' true true
  run dev_home_finding "${tmp}/Dockerfile" dev
  assert_failure 1
  assert_output --partial 'stage base gives HOME /home/dev the mode 3777'

  planted_dockerfile true 'chmod 0777 /home/dev && chmod +t /home/dev' true
  run dev_home_finding "${tmp}/Dockerfile" dev
  assert_failure 1
  assert_output --partial 'stage dev changes HOME /home/dev with the symbolic mode +t'
}

@test "a home directory without the sticky bit, or one changed outside the development stage, is not reported" {
  planted_dockerfile true 'chmod 1777 /cargo /cargo-target && chmod 0777 /home/dev' 'chmod 1777 /home/dev'
  run dev_home_finding "${tmp}/Dockerfile" dev
  assert_success
  assert_output ''

  planted_dockerfile 'mkdir -p /home/dev && chmod 1777 /home/dev' 'chmod 777 "/home/dev"' true
  run dev_home_finding "${tmp}/Dockerfile" dev
  assert_success
  assert_output ''

  planted_dockerfile true 'chmod 1775 /home/dev' true
  run dev_home_finding "${tmp}/Dockerfile" dev
  assert_success
  assert_output ''

  run dev_home_finding "${tmp}/Dockerfile" builder
  assert_failure 2
  assert_output "stage builder not found in ${tmp}/Dockerfile"
}

# --- G26, G27, G31 ------------------------------------------------------------------------------------------

# bats test_tags=slow
@test "docs-check: a command that is no Make target fails with a rule (1) line" {
  printf 'Run \x60make no-such-target\x60 to see it fail.\n' >"${tmp}/line"
  plant_append README.md "${tmp}/line"
  run make --no-print-directory docs-check
  assert_failure
  assert_output --regexp '\(1\) README\.md:[0-9]+: .*no-such-target'
}

@test "validate-architecture-model: a line that does not parse fails with the error of the parser" {
  require_docker
  plant_append workspace.dsl "${fixtures}/broken_relationship.dsl.txt"
  run make --no-print-directory validate-architecture-model
  assert_failure
  assert_output --regexp 'Unexpected tokens at line [0-9]+ of /work/workspace\.dsl: planted -> nowhere'
  assert_output --partial 'does not parse'
}

@test "validate-invariants: another toolchain version fails with a rule (c) line" {
  sed -E 's/^(channel[[:space:]]*=[[:space:]]*)"[^"]*"/\1"1.0.0"/' rust-toolchain.toml >"${tmp}/toolchain"
  plant_replace rust-toolchain.toml "${tmp}/toolchain"
  run make --no-print-directory validate-invariants
  assert_failure
  assert_output --regexp '\(c\) .*toolchain versions differ'
}
