#!/usr/bin/env bats
# Tests of scripts/check-invariants.sh (gate G31, rules (a) to (h)) on small trees generated in the test's
# temporary directory (architecture-delivery.md "CLI Tests (Bats)", file check_invariants.bats). The script is
# called directly, because Make reports every failed recipe with status 2 and the tests assert status 1.

bats_require_minimum_version 1.8.0
load test_helper

# bats file_tags=repository

setup() {
  _common_setup
  script="${REPO_ROOT}/scripts/check-invariants.sh"
  tree="${BATS_TEST_TMPDIR}/tree"
  d64="$(printf 'a%.0s' {1..64})"
  d40="$(printf 'b%.0s' {1..40})"
  repo_name="rust-service-"
  repo_name+="template"
  make_tree
}

teardown() {
  restore_planted
}

# --- the tree ----------------------------------------------------------------------------------------------

# Writes a file of the tree from standard input; the placeholders @T@ (a tab at the start of a line), @D64@ and
# @D40@ and @NAME@ (the repository name) are replaced.
put() {
  local path="${tree}/$1"
  mkdir -p "$(dirname "${path}")"
  cat >"${path}"
  sed -i -e 's/^@T@/\t/' -e "s/@D64@/${d64}/g" -e "s/@D40@/${d40}/g" -e "s/@NAME@/${repo_name}/g" "${path}"
}

# Writes a Bats file of the tree with the given file tags (the tag lines are assembled, because Bats reads a tag
# line wherever it stands in this file, also inside a here-document).
put_bats() {
  local name="$1" tag
  shift
  {
    for tag in "$@"; do
      printf '# bats %s=%s\n' file_tags "${tag}"
    done
    printf '@test "x" { true; }\n'
  } | put "tests/CLI/bats/${name}"
}

# A tree that satisfies every rule: two gates and the Bats job, three workflows, images, pins and sources.
make_tree() {
  mkdir -p "${tree}"
  put Makefile <<'EOF'
include make/tool-versions.mk
include make/gates.mk
EXEC :=

.PHONY: ci-list fmt lint bats install check

ci-list:
@T@@printf '%s\n' fmt lint bats

fmt:
@T@$(EXEC) $(FMT_CMD)

lint:
@T@$(EXEC) cargo clippy --locked

bats:
@T@scripts/hello.sh

install:
@T@scripts/install-tools.sh
@T@cargo fetch --locked

check:
@T@$(EXEC) cargo run --locked -p service -- check-config
@T@$(EXEC) cargo tree --locked | scripts/pipe.sh
EOF
  put make/gates.mk <<'EOF'
FMT_CMD = cargo fmt --all --check
EOF
  put make/tool-versions.mk <<'EOF'
export CARGO_NEXTEST_VERSION := 0.9.151
export TAPLO_VERSION         := 0.10.0
export CARGO_CHEF_VERSION    := 0.1.78
export DEVCONTAINER_CLI_VERSION := 0.90.0
export CARGO_BINSTALL_SHA256_X86_64 := @D64@
export BATS_CORE := v1.14.0 @D40@
export STRUCTURIZR_IMAGE := structurizr/structurizr:2026.10.26@sha256:@D64@
export K6_IMAGE ?= grafana/k6:2.3.0@sha256:@D64@
EOF
  put Dockerfile <<'EOF'
# syntax=docker/dockerfile:1.27@sha256:@D64@
FROM rust:1.99.1-slim-trixie@sha256:@D64@ AS base
WORKDIR /app
FROM base AS chef
ARG CARGO_CHEF_VERSION=0.1.78
RUN cargo install cargo-chef --locked --version "${CARGO_CHEF_VERSION}"
FROM chef AS builder
RUN cargo build --release
FROM gcr.io/distroless/cc-debian13:nonroot@sha256:@D64@ AS prod
LABEL org.opencontainers.image.licenses="CC0-1.0"
COPY --from=builder /app/target/release/service /app/service
EOF
  put docker-compose.yml <<'EOF'
services:
  app:
    image: ${APP_IMAGE:-service:prod}
  database:
    image: postgres:${DB_VERSION:-16}-alpine
  viewer:
    image: structurizr/structurizr:2026.10.26@sha256:@D64@
EOF
  put .devcontainer/devcontainer.json <<'EOF'
{
  "name": "service-dev",
  "features": {
    // docker-in-docker
    "ghcr.io/devcontainers/features/docker-in-docker@sha256:@D64@": {
      "moby": false
    },
    "ghcr.io/devcontainers/features/common-utils@sha256:@D64@": {}
  },
  "remoteUser": "dev"
}
EOF
  put rust-toolchain.toml <<'EOF'
[toolchain]
channel = "1.99.1"
profile = "minimal"
EOF
  put Cargo.toml <<'EOF'
[workspace]
members = ["crates/a"]

[workspace.package]
version = "0.1.0"
rust-version = "1.99.1"
license = "CC0-1.0"
EOF
  put crates/a/Cargo.toml <<'EOF'
[package]
name = "a"
version.workspace = true
license.workspace = true
EOF
  put crates/a/src/lib.rs <<'EOF'
//! Mentions of `#[allow` in a comment are not attributes.
#![forbid(unsafe_code)]

pub mod inner;
EOF
  put crates/a/src/inner.rs <<'EOF'
#![expect(clippy::unwrap_used, reason = "the unused word of a reason is not a lint group")]

pub fn inner() {}
EOF
  put LICENSE <<'EOF'
Creative Commons Legal Code

CC0 1.0 Universal
EOF
  put README.md <<'EOF'
# Service

## License

This project is released under [CC0-1.0](LICENSE).
EOF
  put tests/Load/package.json <<'EOF'
{
  "name": "load",
  "license": "CC0-1.0"
}
EOF
  put .github/openapi-spec/spec.yaml <<'EOF'
openapi: 3.1.0
info:
  title: Service API
  license:
    name: CC0-1.0
    url: https://creativecommons.org/publicdomain/zero/1.0/
  version: 1.0.0
EOF
  put scripts/hello.sh <<'EOF'
#!/usr/bin/env bash
echo hello
EOF
  put scripts/pipe.sh <<'EOF'
#!/usr/bin/env bash
cat
EOF
  put scripts/install-tools.sh <<'EOF'
#!/usr/bin/env bash
cargo install --locked --version 1.0.0 something
EOF
  put_bats sample.bats surface
  put docs/repository-settings.md <<'EOF'
# Repository settings

| Job | Check |
| --- | --- |
| `fmt` | Formatting |
| `lint` | Lint |
| `bats-group` | Bats group |
| `bats` | Bats |
EOF
  put .github/workflows/quality.yml <<'EOF'
name: Quality
on:
  pull_request:
    branches: [main]
permissions:
  contents: read
concurrency:
  group: quality
  cancel-in-progress: true
jobs:
  fmt:
    runs-on: ubuntu-24.04
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@@D40@ # v7.0.1
      - uses: taiki-e/install-action@@D40@ # v2.90.3
        with:
          tool: cargo-nextest@0.9.151,taplo@0.10.0
      - run: make fmt
  lint:
    runs-on: ubuntu-24.04
    timeout-minutes: 20
    permissions:
      contents: read
      security-events: write
    steps:
      - uses: actions/checkout@@D40@ # v7.0.1
      - run: |
          make lint
EOF
  put .github/workflows/tests.yml <<'EOF'
name: Tests
on:
  pull_request:
    branches: [main]
permissions:
  contents: read
concurrency:
  group: tests
  cancel-in-progress: true
jobs:
  bats-group:
    runs-on: ubuntu-24.04
    timeout-minutes: 30
    strategy:
      matrix:
        include:
          - group: surface
          - group: repository
    steps:
      - uses: actions/checkout@@D40@ # v7.0.1
      - run: make bats BATS_ARGS="--filter-tags $GROUP"
        env:
          GROUP: ${{ matrix.group }}
  bats:
    runs-on: ubuntu-24.04
    timeout-minutes: 5
    steps:
      - run: echo done
EOF
}

# Runs the script on the tree.
check() {
  run "${script}" --root "${tree}"
}

# Asserts a violation: status 1 and a line that starts with the rule letter and contains the text.
assert_violation() {
  local rule="$1" text="$2"
  assert_failure 1
  assert_line --regexp "^\\(${rule}\\) .*${text}"
}

# Replaces the first occurrence of a text in a file of the tree and fails when the text is not there.
replace() {
  local path="${tree}/$1" old="$2" new="$3" content
  content="$(cat "${path}")"
  [[ "${content}" == *"${old}"* ]] || {
    echo "the text '${old}' is not in $1" >&2
    return 1
  }
  printf '%s\n' "${content/"${old}"/"${new}"}" >"${path}"
}

# Appends text to a file of the tree; @T@ at the start of a line becomes a tab.
append() {
  mkdir -p "$(dirname "${tree}/$1")"
  printf '%s\n' "$2" | sed 's/^@T@/\t/' >>"${tree}/$1"
}

# --- the valid tree and the command line ---------------------------------------------------------------------

@test "a tree that satisfies every rule passes and prints nothing" {
  check
  assert_success
  assert_output ''
}

@test "an unknown option exits 2" {
  run "${script}" --nope
  assert_failure 2
}

@test "a root that is not a directory exits 2" {
  run "${script}" --root "${tree}/missing"
  assert_failure 2
}

@test "the real repository has no finding of the rules (b), (c), (e), (f), (g) and (h)" {
  run "${script}" --root "${REPO_ROOT}"
  local findings="${output}"
  run grep -E '^\((b|c|e|f|g|h)\) ' <<<"${findings}"
  assert_failure 1
}

@test "the release job and the sync job may write with their own permissions block (a)" {
  put .github/workflows/release.yml <<'EOF'
name: Release
on:
  push:
    branches: [main]
permissions:
  contents: read
concurrency:
  group: release
  cancel-in-progress: false
jobs:
  release:
    runs-on: ubuntu-24.04
    timeout-minutes: 15
    permissions:
      contents: write
    steps:
      - run: echo release
EOF
  check
  assert_success
  assert_output ''
}

# --- rule (a) ------------------------------------------------------------------------------------------------

@test "(a) uses: actions/checkout@v7 is not pinned to a commit" {
  replace .github/workflows/quality.yml "actions/checkout@${d40} # v7.0.1" 'actions/checkout@v7'
  check
  assert_violation a 'actions/checkout@v7 is not pinned'
}

@test "(a) a uses: pinned to a short SHA is refused" {
  replace .github/workflows/quality.yml "actions/checkout@${d40} # v7.0.1" 'actions/checkout@3d3c42e # v7.0.1'
  check
  assert_violation a 'is not pinned'
}

@test "(a) a workflow without permissions is refused" {
  replace .github/workflows/quality.yml $'permissions:\n  contents: read\n' ''
  check
  assert_violation a 'declares no permissions'
}

@test "(a) a workflow without concurrency is refused" {
  replace .github/workflows/quality.yml $'concurrency:\n  group: quality\n  cancel-in-progress: true\n' ''
  check
  assert_violation a 'declares no concurrency'
}

@test "(a) a job without timeout-minutes is refused" {
  replace .github/workflows/quality.yml $'    timeout-minutes: 10\n' ''
  check
  assert_violation a 'job fmt has no timeout-minutes'
}

@test "(a) a job-level permissions block without contents: read is refused" {
  replace .github/workflows/quality.yml $'      contents: read\n      security-events: write' '      security-events: write'
  check
  assert_violation a 'job lint has a permissions block without contents: read'
}

@test "(a) a top-level permissions block that grants write access is refused" {
  replace .github/workflows/quality.yml $'permissions:\n  contents: read\nconcurrency:' $'permissions:\n  contents: write\nconcurrency:'
  check
  assert_violation a 'quality.yml: line 6: the top-level permissions block grants write access'
}

@test "(a) a top-level permissions: write-all is refused and a comment that says write is not" {
  replace .github/workflows/quality.yml $'permissions:\n  contents: read\nconcurrency:' $'permissions: write-all\nconcurrency:'
  check
  assert_violation a 'the top-level permissions block grants write access'
  replace .github/workflows/quality.yml 'permissions: write-all' $'permissions:\n  contents: read # never write here'
  check
  assert_success
}

# --- rule (b) ------------------------------------------------------------------------------------------------

@test "(b) a Dockerfile image with the tag latest is refused" {
  replace Dockerfile 'rust:1.99.1-slim-trixie' 'rust:latest'
  check
  assert_violation b 'uses the tag latest'
}

@test "(b) a Dockerfile image without a digest is refused" {
  replace Dockerfile "cc-debian13:nonroot@sha256:${d64}" 'cc-debian13:nonroot'
  check
  assert_violation b 'has no digest'
}

@test "(b) a Dockerfile image without a version tag is refused" {
  replace Dockerfile "cc-debian13:nonroot@sha256:${d64}" "cc-debian13@sha256:${d64}"
  check
  assert_violation b 'has no version tag'
}

@test "(b) a BuildKit frontend of the syntax line without a digest is refused" {
  replace Dockerfile "# syntax=docker/dockerfile:1.27@sha256:${d64}" '# syntax=docker/dockerfile:1'
  check
  assert_violation b 'Dockerfile:1: image docker/dockerfile:1 has no digest'
}

@test "(b) a BuildKit frontend of the syntax line without a version tag or with the tag latest is refused" {
  replace Dockerfile "# syntax=docker/dockerfile:1.27@sha256:${d64}" "# syntax=docker/dockerfile@sha256:${d64}"
  check
  assert_violation b 'Dockerfile:1: image docker/dockerfile@sha256:.* has no version tag'
  replace Dockerfile "# syntax=docker/dockerfile@sha256:${d64}" "# syntax=docker/dockerfile:latest@sha256:${d64}"
  check
  assert_violation b 'Dockerfile:1: image docker/dockerfile:latest@sha256:.* uses the tag latest'
}

@test "(b) an unpinned syntax line after an escape directive is refused" {
  replace Dockerfile "# syntax=docker/dockerfile:1.27@sha256:${d64}" $'# escape=`\n# check=skip=JSONArgsRecommended\n# syntax=docker/dockerfile:1'
  check
  assert_violation b 'Dockerfile:3: image docker/dockerfile:1 has no digest'
}

@test "(b) a pinned syntax line after an escape directive is accepted" {
  replace Dockerfile "# syntax=docker/dockerfile:1.27@sha256:${d64}" $'# escape=`\n# syntax=docker/dockerfile:1.27@sha256:'"${d64}"
  check
  assert_success
}

@test "(b) a syntax line after a comment is not read as a parser directive even behind an escape directive" {
  replace Dockerfile "# syntax=docker/dockerfile:1.27@sha256:${d64}" $'# escape=`\n# a comment\n# syntax=docker/dockerfile:1'
  check
  assert_success
}

@test "(b) a comment that mentions syntax after the first line is not read as the parser directive" {
  replace Dockerfile 'WORKDIR /app' $'# syntax=anything\nWORKDIR /app'
  check
  assert_success
}

@test "(b) a compose image without a digest is refused" {
  replace docker-compose.yml "structurizr/structurizr:2026.10.26@sha256:${d64}" 'structurizr/structurizr:2026.10.26'
  check
  assert_violation b 'docker-compose.yml.*has no digest'
}

@test "(b) a compose image with the tag latest is refused" {
  append docker-compose.yml '  cache:'
  append docker-compose.yml "    image: redis:latest@sha256:${d64}"
  check
  assert_violation b 'redis:latest.*uses the tag latest'
}

@test "(b) the database image with DB_VERSION is the one exception, another service is not" {
  append docker-compose.yml '  replica:'
  append docker-compose.yml "    image: postgres:\${DB_VERSION:-16}-alpine"
  check
  assert_violation b 'docker-compose.yml:[0-9]+: image postgres:.*DB_VERSION.*has no digest'
  # The exempt line of the database service is not reported: only the appended line is.
  local database_line
  database_line="$(grep -n 'image: postgres:.*DB_VERSION' "${tree}/docker-compose.yml" | head -n 1 | cut -d: -f1)"
  [[ -n "${database_line}" ]]
  refute_line --regexp "^\\(b\\) docker-compose.yml:${database_line}:"
}

@test "(b) a development-container feature referenced by tag is refused" {
  replace .devcontainer/devcontainer.json "common-utils@sha256:${d64}" 'common-utils:2'
  check
  assert_violation b 'feature ghcr.io/devcontainers/features/common-utils:2 is not referenced by digest'
}

@test "(b) a tool image of make/tool-versions.mk without a digest is refused" {
  replace make/tool-versions.mk "grafana/k6:2.3.0@sha256:${d64}" 'grafana/k6:2.3.0'
  check
  assert_violation b 'K6_IMAGE.*has no digest'
}

@test "(b) a tool version of make/tool-versions.mk that is not exact is refused" {
  replace make/tool-versions.mk 'CARGO_NEXTEST_VERSION := 0.9.151' 'CARGO_NEXTEST_VERSION := 0.9'
  check
  assert_violation b 'CARGO_NEXTEST_VERSION has no exact version'
}

@test "(b) a Bats pin without a commit SHA is refused" {
  replace make/tool-versions.mk "BATS_CORE := v1.14.0 ${d40}" 'BATS_CORE := v1.14.0'
  check
  assert_violation b 'BATS_CORE'
}

@test "(b) a tool: entry of a workflow that differs from make/tool-versions.mk is refused" {
  replace .github/workflows/quality.yml 'cargo-nextest@0.9.151' 'cargo-nextest@0.9.150'
  check
  assert_violation b 'cargo-nextest@0.9.150 differs from CARGO_NEXTEST_VERSION 0.9.151'
}

@test "(b) a tool: entry without an exact version is refused" {
  replace .github/workflows/quality.yml 'taplo@0.10.0' 'taplo'
  check
  assert_violation b 'tool taplo has no exact version'
}

@test "(b) a tool: entry that has no pin is refused" {
  replace .github/workflows/quality.yml 'taplo@0.10.0' 'unknown-tool@1.0.0'
  check
  assert_violation b 'tool unknown-tool has no pin'
}

@test "(b) the @devcontainers/cli version of a workflow that differs from the pin is refused" {
  replace .github/workflows/tests.yml '      - run: echo done' '      - run: npx --yes @devcontainers/cli@0.89.0 build --workspace-folder .'
  check
  assert_violation b '@devcontainers/cli@0.89.0 differs from DEVCONTAINER_CLI_VERSION 0.90.0'
}

@test "(b) npx without an exact version is refused" {
  replace .github/workflows/tests.yml '      - run: echo done' '      - run: npx --yes prettier --check .'
  check
  assert_violation b 'npx runs prettier without an exact version'
}

@test "(b) a cargo-chef version of the Dockerfile that differs from the pin is refused" {
  replace Dockerfile 'ARG CARGO_CHEF_VERSION=0.1.78' 'ARG CARGO_CHEF_VERSION=0.1.77'
  check
  assert_violation b 'cargo-chef 0.1.77 differs from CARGO_CHEF_VERSION 0.1.78'
}

@test "(b) a cargo install without --version in the Dockerfile is refused" {
  replace Dockerfile "--locked --version \"\${CARGO_CHEF_VERSION}\"" '--locked'
  check
  assert_violation b 'Dockerfile.*has no exact version'
}

@test "(b) a Structurizr version of a compose file that differs from the pin is refused" {
  replace docker-compose.yml "structurizr/structurizr:2026.10.26@sha256:${d64}" "structurizr/structurizr:2026.10.25@sha256:${d64}"
  check
  assert_violation b 'structurizr/structurizr:2026.10.25.*differs from STRUCTURIZR_IMAGE'
}

@test "(b) a container image of a workflow with the tag latest is refused" {
  replace .github/workflows/quality.yml $'  lint:\n    runs-on: ubuntu-24.04' $'  lint:\n    container: alpine:latest\n    runs-on: ubuntu-24.04'
  check
  assert_violation b 'alpine:latest'
}

@test "(b) a file downloaded by URL without a checksum is refused" {
  put scripts/fetch.sh <<'EOF'
#!/usr/bin/env bash
curl --fail --location --output /tmp/tool.tar.gz https://example.org/tool.tar.gz
EOF
  check
  assert_violation b 'scripts/fetch.sh.*downloaded by URL without a checksum'
}

@test "(b) a download without a checksum in a script outside scripts/ is refused" {
  put tests/Load/fetch.sh <<'EOF'
#!/usr/bin/env bash
curl --fail --location --output /tmp/tool.tar.gz https://example.org/tool.tar.gz
EOF
  put .githooks/pre-push <<'EOF'
#!/usr/bin/env bash
wget https://example.org/hook.tar.gz
EOF
  put tests/CLI/bats/helper.bash <<'EOF'
curl --fail --location --output /tmp/x https://example.org/x
EOF
  check
  assert_violation b 'tests/Load/fetch.sh: a file is downloaded by URL without a checksum'
  assert_line '(b) .githooks/pre-push: a file is downloaded by URL without a checksum'
  assert_line '(b) tests/CLI/bats/helper.bash: a file is downloaded by URL without a checksum'
}

@test "(b) a download in a fixture of the Bats tests is not read" {
  put tests/CLI/bats/fixtures/fetch.sh <<'EOF'
#!/usr/bin/env bash
curl --fail --location --output /tmp/tool.tar.gz https://example.org/tool.tar.gz
EOF
  check
  assert_success
  assert_output ''
}

@test "(b) a request to the loopback interface is a probe, not a download" {
  put tests/CLI/bats/probe.bash <<'EOF'
probe() {
  curl --noproxy '*' --silent --output /dev/null --max-time 10 "http://127.0.0.1:${APP_PORT}/ping"
  curl --silent --fail http://localhost:8081/health
  wget -q -O /dev/null http://[::1]:8081/ping
  curl -fsS http://localhost:8080/health || exit 1
}
EOF
  check
  assert_success
  assert_output ''
}

@test "(b) a download from a host that only starts with localhost is refused" {
  put tests/Load/fetch.sh <<'EOF'
#!/usr/bin/env bash
curl --fail --output /tmp/x http://localhost.example.org/x
EOF
  check
  assert_violation b 'tests/Load/fetch.sh: a file is downloaded by URL without a checksum'
}

@test "(b) a remote host behind a loopback user name is refused" {
  put scripts/fetch.sh <<'EOF'
#!/usr/bin/env bash
curl --fail --output /tmp/x http://localhost@remote.example.org/x
EOF
  put scripts/fetch-port.sh <<'EOF'
#!/usr/bin/env bash
curl --fail --output /tmp/x http://127.0.0.1:80@remote.example.org/x
EOF
  check
  assert_violation b 'scripts/fetch.sh: a file is downloaded by URL without a checksum'
  assert_line '(b) scripts/fetch-port.sh: a file is downloaded by URL without a checksum'
}

@test "(b) a download through a loopback proxy from an address in a variable is refused" {
  put scripts/fetch.sh <<'EOF'
#!/usr/bin/env bash
curl --proxy http://127.0.0.1:3128 --fail --location --output tool.tgz "${TOOL_URL}"
EOF
  put scripts/fetch-comment.sh <<'EOF'
#!/usr/bin/env bash
curl -fsSL -o tool.tgz "$TOOL_URL" # like http://localhost:1/
EOF
  check
  assert_violation b 'scripts/fetch.sh: a file is downloaded by URL without a checksum'
  assert_line '(b) scripts/fetch-comment.sh: a file is downloaded by URL without a checksum'
}

@test "(b) a download through a loopback proxy on a continued line or without a download option is refused" {
  put scripts/fetch-continued.sh <<'EOF'
#!/usr/bin/env bash
curl --proxy http://127.0.0.1:3128 \
  -fsSL -o tool.tgz https://example.org/tool.tgz
EOF
  put scripts/fetch-piped.sh <<'EOF'
#!/usr/bin/env bash
curl --proxy http://127.0.0.1:3128 "${TOOL_URL}" | tar -xz
EOF
  check
  assert_violation b 'scripts/fetch-continued.sh: a file is downloaded by URL without a checksum'
  assert_line '(b) scripts/fetch-piped.sh: a file is downloaded by URL without a checksum'
}

@test "(b) a probe and a download on one line are refused" {
  put scripts/fetch-and.sh <<'EOF'
#!/usr/bin/env bash
curl -fsS http://localhost:8080/health && curl -fsSLO example.org/tool.tgz
EOF
  put scripts/fetch-wget.sh <<'EOF'
#!/usr/bin/env bash
curl -fsS http://localhost:8080/health; wget -O tool.tgz example.org/tool.tgz
EOF
  put scripts/fetch-two.sh <<'EOF'
#!/usr/bin/env bash
curl -fsSLo tool.tgz http://localhost:1/ example.org/tool.tgz
EOF
  put scripts/fetch-backtick.sh <<'EOF'
#!/usr/bin/env bash
curl -fsS http://localhost:8080/health; curl -fsSLO `cat url.txt`
EOF
  put scripts/fetch-connect.sh <<'EOF'
#!/usr/bin/env bash
curl --connect-to localhost:80:example.org:80 -fsSLO http://localhost/tool.tgz
EOF
  check
  assert_violation b 'scripts/fetch-and.sh: a file is downloaded by URL without a checksum'
  assert_line '(b) scripts/fetch-wget.sh: a file is downloaded by URL without a checksum'
  assert_line '(b) scripts/fetch-two.sh: a file is downloaded by URL without a checksum'
  assert_line '(b) scripts/fetch-backtick.sh: a file is downloaded by URL without a checksum'
  assert_line '(b) scripts/fetch-connect.sh: a file is downloaded by URL without a checksum'
}

@test "(b) a loopback URL beside a remote address without a scheme or a name override or proxy option is refused" {
  put scripts/fetch-resolve.sh <<'EOF'
#!/usr/bin/env bash
curl --resolve localhost:80:93.184.216.34 -fsSLO http://localhost/tool.tgz
EOF
  put scripts/fetch-ipv4.sh <<'EOF'
#!/usr/bin/env bash
curl -fsSLO http://localhost:1/ 93.184.216.34/tool
EOF
  put scripts/fetch-ipv4-bare.sh <<'EOF'
#!/usr/bin/env bash
curl -fsSL http://localhost:1/ 93.184.216.34 >tool
EOF
  put scripts/fetch-word.sh <<'EOF'
#!/usr/bin/env bash
curl -fsSLO http://localhost/x intranet/tool
EOF
  put scripts/fetch-socks.sh <<'EOF'
#!/usr/bin/env bash
curl -x socks5h://127.0.0.1:9050 -fsSLO tool
EOF
  put scripts/fetch-resolve6.sh <<'EOF'
#!/usr/bin/env bash
curl --resolve localhost:80:[2001:db8::1] -fsSLO http://localhost/tool
EOF
  put scripts/fetch-connect-word.sh <<'EOF'
#!/usr/bin/env bash
curl --connect-to localhost:80:intranet:80 -fsSLO http://localhost/tool
EOF
  put scripts/fetch-preproxy.sh <<'EOF'
#!/usr/bin/env bash
curl --preproxy socks5://127.0.0.1:1080 -fsSLO http://localhost/tool
EOF
  put scripts/fetch-socks-option.sh <<'EOF'
#!/usr/bin/env bash
curl --socks5-hostname 127.0.0.1:9050 -fsSLO http://localhost/tool
EOF
  put scripts/fetch-proxy-cluster.sh <<'EOF'
#!/usr/bin/env bash
curl -fsSLOx http://127.0.0.1:3128 http://localhost/tool
EOF
  put scripts/fetch-proxy-variable.sh <<'EOF'
#!/usr/bin/env bash
https_proxy=http://127.0.0.1:3128 curl -fsSLO http://localhost/tool
EOF
  check
  assert_failure
  local name
  for name in resolve ipv4 ipv4-bare word socks resolve6 connect-word preproxy socks-option proxy-cluster proxy-variable; do
    assert_line "(b) scripts/fetch-${name}.sh: a file is downloaded by URL without a checksum"
  done
}

@test "(b) a probe in a command substitution is a probe, a download in one is not" {
  put tests/CLI/bats/probe.bash <<'EOF'
probe() {
  status=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8080/ping)
  body="$(wget -q -O - http://[::1]:8081/ping)"
}
EOF
  check
  assert_success
  assert_output ''
  put scripts/fetch-substitution.sh <<'EOF'
#!/usr/bin/env bash
out=$(curl -fsSLo tool http://localhost:1/ "$TOOL_URL")
EOF
  check
  assert_violation b 'scripts/fetch-substitution.sh: a file is downloaded by URL without a checksum'
}

@test "(b) a downloaded file with a checksum passes" {
  put scripts/fetch.sh <<'EOF'
#!/usr/bin/env bash
curl --fail --location --output /tmp/tool.tar.gz https://example.org/tool.tar.gz
echo "expected  /tmp/tool.tar.gz" | sha256sum --check -
EOF
  check
  assert_success
}

# --- rule (c) ------------------------------------------------------------------------------------------------

@test "(c) rust-version that differs from rust-toolchain.toml and the builder tag is refused" {
  replace Cargo.toml 'rust-version = "1.99.1"' 'rust-version = "1.99.0"'
  check
  assert_violation c 'toolchain versions differ'
}

@test "(c) a channel that differs from the builder image tag is refused" {
  replace rust-toolchain.toml 'channel = "1.99.1"' 'channel = "1.99.2"'
  check
  assert_violation c 'toolchain versions differ: rust-toolchain.toml 1.99.2, builder image 1.99.1'
}

@test "(c) a builder image tag that differs from the toolchain is refused" {
  replace Dockerfile 'rust:1.99.1-slim-trixie' 'rust:1.98.0-slim-trixie'
  check
  assert_violation c 'builder image 1.98.0'
}

@test "(c) a channel that is not a full version is refused" {
  replace rust-toolchain.toml 'channel = "1.99.1"' 'channel = "stable"'
  check
  assert_violation c 'channel is missing or is not a full version'
}

# --- rule (d) ------------------------------------------------------------------------------------------------

@test "(d) a workflow set that omits a gate target of make ci-list is refused" {
  replace .github/workflows/quality.yml '      - run: make fmt' '      - run: echo skipped'
  check
  assert_violation d 'gate target fmt of make ci-list is run by no pull-request workflow'
}

@test "(d) a gate target that only a workflow without a pull_request trigger runs is refused" {
  replace .github/workflows/quality.yml '      - run: make fmt' '      - run: echo skipped'
  put .github/workflows/scheduled.yml <<'EOF'
name: Scheduled
on:
  schedule:
    - cron: '0 3 * * 1'
  workflow_dispatch:
permissions:
  contents: read
concurrency:
  group: scheduled
  cancel-in-progress: false
jobs:
  weekly:
    runs-on: ubuntu-24.04
    timeout-minutes: 10
    steps:
      - run: make fmt
EOF
  check
  assert_violation d 'gate target fmt of make ci-list is run by no pull-request workflow'
}

@test "(d) a scheduled workflow that repeats a gate of a pull-request workflow or runs a CI-only target is accepted" {
  put .github/workflows/scheduled.yml <<'EOF'
name: Scheduled
on:
  schedule:
    - cron: '0 3 * * 1'
permissions:
  contents: read
concurrency:
  group: scheduled
  cancel-in-progress: false
jobs:
  weekly:
    runs-on: ubuntu-24.04
    timeout-minutes: 10
    steps:
      - run: make fmt lint
      - run: make bootstrap && make ci
EOF
  check
  assert_success
  assert_output ''
}

@test "(d) a target outside make ci-list in a workflow without a pull_request trigger is refused" {
  put .github/workflows/scheduled.yml <<'EOF'
name: Scheduled
on:
  schedule:
    - cron: '0 3 * * 1'
permissions:
  contents: read
concurrency:
  group: scheduled
  cancel-in-progress: false
jobs:
  weekly:
    runs-on: ubuntu-24.04
    timeout-minutes: 10
    steps:
      - run: make extra-gate
EOF
  check
  assert_violation d 'make extra-gate, which is not a gate target'
}

@test "(d) a workflow that runs a target outside make ci-list is refused" {
  replace .github/workflows/tests.yml '      - run: echo done' '      - run: make extra-gate'
  check
  assert_violation d 'make extra-gate, which is not a gate target'
}

@test "(d) a CI-only target in a workflow is not a finding" {
  replace .github/workflows/tests.yml '      - run: echo done' '      - run: make check-commit-message'
  check
  assert_success
}

@test "(d) a tree without workflow files is refused" {
  rm -rf "${tree}/.github/workflows"
  check
  assert_violation d 'no workflow files'
}

@test "(d) a Bats file without a group tag is refused" {
  put_bats untagged.bats
  check
  assert_violation d 'untagged.bats: 0 file tags'
}

@test "(d) a Bats file with two file tags is refused" {
  put_bats double.bats surface quality
  check
  assert_violation d 'double.bats: 2 file tags'
}

@test "(d) a Bats file whose tag is not a group of the matrix is refused" {
  put_bats other.bats elsewhere
  check
  assert_violation d "other.bats: file tag 'elsewhere' is not a group"
}

@test "(d) a job name missing from docs/repository-settings.md is refused" {
  replace docs/repository-settings.md "| \`lint\` | Lint |" ''
  check
  assert_violation d 'quality.yml: job lint is missing from docs/repository-settings.md'
}

@test "(d) a pull-request workflow without the settings document is refused" {
  rm "${tree}/docs/repository-settings.md"
  check
  assert_violation d 'docs/repository-settings.md is missing'
}

@test "(d) a job listed only in the service-owned docs/repository-settings-service.md is accepted" {
  replace docs/repository-settings.md "| \`lint\` | Lint |" ''
  put docs/repository-settings-service.md <<'EOF'
| Job | Check name | Required |
| --- | --- | --- |
| `lint` | Lint | yes |
EOF
  check
  assert_success
}

@test "(d) a job listed in neither settings document is refused when the service document exists" {
  replace docs/repository-settings.md "| \`lint\` | Lint |" ''
  put docs/repository-settings-service.md <<'EOF'
| `other` | Other | yes |
EOF
  check
  assert_violation d 'quality.yml: job lint is missing from docs/repository-settings.md \(or docs/repository-settings-service.md\)'
}

# --- rule (e) ------------------------------------------------------------------------------------------------

@test "(e) the repository name in a script is refused" {
  append scripts/clone.sh "git clone https://example.org/org/${repo_name}"
  check
  assert_violation e 'scripts/clone.sh:1'
}

@test "(e) the repository name in a workflow other than the sync workflows is refused" {
  replace .github/workflows/tests.yml '      - run: echo done' "      - run: echo ${repo_name}"
  check
  assert_violation e '.github/workflows/tests.yml'
}

@test "(e) the repository name in a test of a crate, of xtask or of the features is refused" {
  append crates/a/tests/identity.rs "const NAME: &str = \"${repo_name}\";"
  append xtask/src/tests.rs "// ${repo_name}"
  append features/identity.feature "Scenario: ${repo_name}"
  check
  assert_violation e 'crates/a/tests/identity.rs:1'
  assert_line --regexp '^\(e\) xtask/src/tests\.rs:1'
  assert_line --regexp '^\(e\) features/identity\.feature:1'
}

@test "(e) the repository name in the Makefile and in AGENTS.md is refused" {
  append Makefile "NAME := ${repo_name}"
  append AGENTS.md "The ${repo_name} repository."
  check
  assert_violation e 'Makefile'
  assert_line --regexp '^\(e\) AGENTS.md'
}

@test "(e) the sync source setting of a sync workflow, the README and specs are allowed" {
  put .github/workflows/template-sync-app.yml <<'EOF'
name: Template sync
on:
  workflow_dispatch:
permissions:
  contents: read
concurrency:
  group: template-sync
  cancel-in-progress: false
env:
  TEMPLATE_REPOSITORY: VilnaCRM-Org/@NAME@
jobs:
  sync:
    runs-on: ubuntu-24.04
    timeout-minutes: 15
    permissions:
      contents: write
    steps:
      - run: echo sync
EOF
  append README.md "Badge: https://github.com/VilnaCRM-Org/${repo_name}"
  append specs/plan.md "The ${repo_name} plan."
  append bmalph/config.json "{ \"name\": \"${repo_name}\" }"
  check
  assert_success
  assert_output ''
}

@test "(e) the repository name in a sync workflow outside the source setting is refused" {
  put .github/workflows/template-sync-pat.yml <<'EOF'
name: Template sync
on:
  workflow_dispatch:
permissions:
  contents: read
concurrency:
  group: template-sync
  cancel-in-progress: false
env:
  TEMPLATE_REPOSITORY: VilnaCRM-Org/@NAME@
jobs:
  sync:
    runs-on: ubuntu-24.04
    timeout-minutes: 15
    steps:
      - run: echo @NAME@
EOF
  check
  assert_violation e 'template-sync-pat.yml:16'
  refute_line --regexp 'template-sync-pat.yml:10'
}

# --- rule (f) ------------------------------------------------------------------------------------------------

@test "(f) a second licence identifier in a crate manifest is refused" {
  put crates/b/Cargo.toml <<'EOF'
[package]
name = "b"
license = "CC0-1.0 OR MIT"
EOF
  check
  assert_violation f 'crates/b/Cargo.toml:3: licence identifier CC0-1.0 OR MIT'
}

@test "(f) another licence in the workspace manifest is refused" {
  replace Cargo.toml 'license = "CC0-1.0"' 'license = "MIT"'
  check
  assert_violation f 'Cargo.toml:.*licence identifier MIT'
}

@test "(f) another licence in tests/Load/package.json is refused" {
  replace tests/Load/package.json '"license": "CC0-1.0"' '"license": "ISC"'
  check
  assert_violation f 'tests/Load/package.json: licence identifier ISC'
}

@test "(f) another licence in the image label is refused" {
  replace Dockerfile 'licenses="CC0-1.0"' 'licenses="Apache-2.0"'
  check
  assert_violation f 'Dockerfile: image label.*Apache-2.0'
}

@test "(f) another licence in the OpenAPI snapshot is refused" {
  replace .github/openapi-spec/spec.yaml 'name: CC0-1.0' 'name: MIT'
  check
  assert_violation f 'spec.yaml: info.license states MIT'
}

@test "(f) another licence in the README licence section is refused" {
  replace README.md 'released under [CC0-1.0](LICENSE).' 'released under the MIT licence.'
  check
  assert_violation f 'README.md: the licence section names another licence'
}

@test "(f) a LICENSE file that is not CC0 is refused" {
  put LICENSE <<'EOF'
MIT License

Copyright (c) someone
EOF
  check
  assert_violation f 'LICENSE: the licence text is not CC0'
}

# --- rule (g) ------------------------------------------------------------------------------------------------

@test "(g) #[allow in a module is refused" {
  put crates/a/src/extra.rs <<'EOF'
#[allow(dead_code)]
fn unused_function() {}
EOF
  check
  assert_violation g 'crates/a/src/extra.rs:1: #\[allow'
}

@test "(g) #![allow in a crate root is refused" {
  replace crates/a/src/lib.rs '#![forbid(unsafe_code)]' '#![allow(dead_code)]'
  check
  assert_violation g 'crates/a/src/lib.rs:2: #\[allow or #!\[allow'
}

@test "(g) #![expect( in a crate root is refused" {
  replace crates/a/src/lib.rs '#![forbid(unsafe_code)]' $'#![expect(\n    dead_code,\n    reason = "fixture"\n)]'
  check
  assert_violation g 'crates/a/src/lib.rs:2: #!\[expect\( in a crate root'
}

@test "(g) #![expect( in the main file of an integration test is refused" {
  put crates/a/tests/integration/main.rs <<'EOF'
#![expect(dead_code, reason = "fixture")]
EOF
  check
  assert_violation g 'crates/a/tests/integration/main.rs:1: #!\[expect\( in a crate root'
}

@test "(g) #![expect( in the build script is refused" {
  put crates/a/build.rs <<'EOF'
#![expect(dead_code, reason = "fixture")]
fn main() {}
EOF
  check
  assert_violation g 'crates/a/build.rs:1: #!\[expect\( in a crate root'
}

@test "(g) a suppression that names clippy::pedantic is refused" {
  put crates/a/src/extra.rs <<'EOF'
#[expect(clippy::pedantic, reason = "fixture")]
fn extra() {}
EOF
  check
  assert_violation g 'crates/a/src/extra.rs:1: an expect names a lint group'
}

@test "(g) a suppression that names a lint group on a later line is refused" {
  put crates/a/src/extra.rs <<'EOF'
#[expect(
    dead_code,
    unused,
    reason = "fixture"
)]
fn extra() {}
EOF
  check
  assert_violation g 'crates/a/src/extra.rs:1: an expect names a lint group'
}

@test "(g) a suppression of one lint with a reason that names a group passes" {
  put crates/a/src/extra.rs <<'EOF'
// A line comment with #[allow(unused)] is not an attribute.
#[expect(clippy::unwrap_used, reason = "clippy::pedantic and unused are only words here")]
fn extra() {}
EOF
  check
  assert_success
  assert_output ''
}

@test "(g) #![cfg_attr(test, expect( in a crate root is refused" {
  replace crates/a/src/lib.rs '#![forbid(unsafe_code)]' '#![cfg_attr(test, expect(clippy::unwrap_used, reason = "fixture"))]'
  check
  assert_violation g 'crates/a/src/lib.rs:2: #!\[expect\( in a crate root'
}

@test "(g) a cfg_attr suppression that names a lint group is refused" {
  put crates/a/src/extra.rs <<'EOF'
#[cfg_attr(
    test,
    expect(clippy::pedantic, reason = "fixture")
)]
fn extra() {}
EOF
  check
  assert_violation g 'crates/a/src/extra.rs:1: an expect names a lint group'
}

@test "(g) #[cfg_attr(.., allow( is refused" {
  put crates/a/src/extra.rs <<'EOF'
#[cfg_attr(not(test), allow(dead_code))]
fn extra() {}
EOF
  check
  assert_violation g 'crates/a/src/extra.rs:1: #\[allow or #!\[allow'
}

@test "(g) an item-level cfg_attr expect of one lint with a reason passes" {
  put crates/a/src/extra.rs <<'EOF'
#[cfg_attr(
    not(test),
    expect(
        clippy::needless_pass_by_value,
        reason = "the signature is fixed by the layer; unused and clippy::pedantic are words here"
    )
)]
fn extra(_value: String) {}

#[cfg_attr(test, derive(Debug))]
struct Plain;
EOF
  check
  assert_success
  assert_output ''
}

# --- rule (h) ------------------------------------------------------------------------------------------------

@test "(h) a recipe that calls cargo without the execution prefix is refused" {
  replace Makefile "\$(EXEC) cargo clippy --locked" 'cargo clippy --locked'
  check
  assert_violation h 'Makefile:.*the recipe of lint starts cargo without'
}

@test "(h) a recipe that starts a toolchain command through env without the prefix is refused" {
  append Makefile $'doc:\n@T@env RUSTDOCFLAGS="-D warnings" cargo doc'
  check
  assert_violation h 'the recipe of doc starts cargo'
}

@test "(h) a recipe that starts a command variable of a toolchain command without the prefix is refused" {
  replace Makefile "\$(EXEC) \$(FMT_CMD)" "\$(FMT_CMD)"
  check
  assert_violation h 'the recipe of fmt starts \$\(FMT_CMD\) \(cargo\) without'
}

@test "(h) a recipe that starts typos, taplo, zizmor or sqlx without the prefix is refused" {
  append Makefile $'spelling:\n@T@@typos\n@T@taplo fmt --check\n@T@-zizmor .github\n@T@sqlx migrate run'
  check
  assert_violation h 'starts typos'
  assert_line --regexp '^\(h\) .*starts taplo'
  assert_line --regexp '^\(h\) .*starts zizmor'
  assert_line --regexp '^\(h\) .*starts sqlx'
}

@test "(h) a script that a recipe calls outside the prefix and that starts cargo is refused" {
  put scripts/hello.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cargo build
EOF
  check
  assert_violation h 'scripts/hello.sh:3: called outside \$\(EXEC\) from Makefile:.*starts a toolchain command'
}

@test "(h) a script on the right of a pipe that starts cargo is refused" {
  put scripts/pipe.sh <<'EOF'
#!/usr/bin/env bash
if cargo metadata; then cat; fi
EOF
  check
  assert_violation h 'scripts/pipe.sh:2: called outside'
}

@test "(h) a script behind the prefix may start cargo, and so may the installer and the preflight" {
  append Makefile "migrate:
@T@\$(EXEC) scripts/setup.sh"
  put scripts/setup.sh <<'EOF'
#!/usr/bin/env bash
sqlx database reset
EOF
  put scripts/doctor.sh <<'EOF'
#!/usr/bin/env bash
cargo --version
EOF
  append Makefile $'doctor:\n@T@@scripts/doctor.sh'
  check
  assert_success
  assert_output ''
}

@test "(h) a toolchain word in text or in a comment of a script is not a command" {
  put scripts/hello.sh <<'EOF'
#!/usr/bin/env bash
# cargo is started by the caller
echo "run cargo and typos behind the switch"
EOF
  check
  assert_success
  assert_output ''
}
