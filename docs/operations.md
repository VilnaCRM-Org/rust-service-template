# Operations

Runbooks for operating the service and for maintaining the repository that hosts it. Every command named here is a Make target (see `docs/make-targets.md`) or a command of the `service` binary. Variable names and defaults are listed in `docs/environment.md`.

## Contents

- [Migrations and rollback](#migrations-and-rollback)
- [Health-probe runbook](#health-probe-runbook)
- [Logs and request ids](#logs-and-request-ids)
- [Shutdown sequence](#shutdown-sequence)
- [Toolchain update procedure](#toolchain-update-procedure)
- [Tool-version review](#tool-version-review)
- [First measurements](#first-measurements)
- [Accepted findings: `.trivyignore` and `.gitleaksignore`](#accepted-findings-trivyignore-and-gitleaksignore)

## Migrations and rollback

Migrations are plain SQL files in `migrations/` at the workspace root, written as reversible pairs: `<UTC timestamp>_<snake_case_name>.up.sql` and `.down.sql`. They are embedded in the `service` binary, so the production image needs neither `sqlx-cli` nor the directory. The service never migrates on start: `serve` starts without touching the schema, and migrating is a separate step.

| Task | Command | Result |
| --- | --- | --- |
| Apply every pending migration to the development database | `make migrate` | `applied <n> migration(s)` on stdout; nothing changes when none is pending |
| Revert the most recently applied migration | `make migrate-rollback` | `reverted <version>` on stdout, or `nothing to revert` |
| Create a new reversible pair | `make create-migration name=<snake_case_description>` | an empty `.up.sql` and `.down.sql` |
| Refresh the committed query metadata after a query changed | `make sqlx-prepare` | updated files in `.sqlx/`, committed with the migration |

Both migration commands wait for the database first: one attempt per second until `DATABASE_WAIT_TIMEOUT` elapses (default 30 seconds). Each failed attempt prints `waiting for database (attempt <n>): <error>` on stderr. When the database stays unreachable the command exits with status 1 and prints the connection error. An invalid configuration exits with status 2.

Migrations run under `DATABASE_STATEMENT_TIMEOUT` like every statement of the service (default 5 seconds, accepted range 1 millisecond to 24 days; PostgreSQL treats 0 as "no limit", so 0 is rejected). A statement that runs longer is cancelled with `canceling statement due to statement timeout`, the command exits with status 1 and the compose service `app`, which waits for `migrate`, does not start. Before a long migration such as an index build or a backfill, raise the variable for the migrate step only, for example `DATABASE_STATEMENT_TIMEOUT=30m make migrate`, or set it in the environment of the `migrate` container.

In a deployed environment the production image runs the same step with its first argument: `migrate` applies and `migrate revert` reverts. The compose files run it as the one-shot service `migrate`, which the service `app` waits for.

Rules:

1. An applied migration is never edited. A migration that has reached `main` may already have run in other environments; correct it with a new migration.
2. Every migration belongs to one bounded context and touches only that context's tables.
3. Write the `.down.sql` file so that it undoes the `.up.sql` file, and run `make migrate-rollback` followed by `make migrate` once before you commit the pair.
4. Commit `.sqlx/` together with the migration when a query changed, or the offline build fails.

Rollback of a deployment:

1. Stop or scale down the new version when it cannot run against the older schema.
2. Run `migrate revert` once per migration of the failed release, newest first. Each call reverts exactly one migration.
3. Deploy the previous image.
4. Check the readiness endpoint `GET /api/health` (see the next section).

A `.down.sql` file that drops a column or table destroys data. Take a backup before a rollback in production and decide whether to restore it.

## Health-probe runbook

`GET /api/health` answers `204` with an empty body when every probe succeeds. Otherwise it answers `500` with a problem document of type `/problems/dependency-unavailable`. Its `failures` member holds one entry per failing dependency, and `detail` joins the messages with a semicolon and a space. The messages are fixed and identical in every environment. The underlying cause is never returned: it is a log line `health probe failed` at `WARN` with the fields `dependency` and `cause` (the whole error chain, outermost first, joined by a colon and a space, for example `probe failed: dispatch failure: <reason>`), and it carries the request id of the probe request.

`GET /ping` is the liveness check. It touches no dependency, so a dependency outage never restarts a healthy process. Use `/ping` for container and process liveness and `/api/health` for readiness behind a load balancer.

All probes run concurrently and each has a deadline of `HEALTH_PROBE_TIMEOUT` (default 3 seconds). A probe that hangs counts as failed, and its `cause` is `timed out after 3s`. The adapters have shorter limits of their own (database pool acquisition 2 seconds, SQS operation 2 seconds), so a refused connection reports its real cause and the outer deadline only catches a dependency that hangs.

To see the cause, filter the log for the probe line:

```sh
docker compose logs app | jq -c 'select(.message == "health probe failed")'
```

### `Database is not available`

Wire identifier: `dependency` is `database`. The probe runs `SELECT 1` on the connection pool.

Likely causes:

- the database is stopped, restarting or unreachable from the service (network, firewall, wrong host or port);
- `DATABASE_URL` is wrong, or the credentials were rotated;
- the pool is exhausted: every connection is busy for longer than `DATABASE_ACQUIRE_TIMEOUT` (default 2 seconds), which is a capacity problem rather than an outage;
- the database accepts connections but the statement exceeds `DATABASE_STATEMENT_TIMEOUT`.

Checks:

1. Read the `cause` of the `health probe failed` line with `dependency` equal to `database`.
2. From the same network as the service, connect with `psql` using the host, port and user of `DATABASE_URL`. Never paste the URL into a ticket: it contains the password.
3. Compare `DATABASE_MAX_CONNECTIONS` with the database's connection limit and with the number of running instances.
4. Look for long-running or locked statements in `pg_stat_activity`.
5. After the database is back, the pool reconnects by itself (the pool is lazy); no restart is needed.

### `Cache is not working`

Wire identifier: `dependency` is `cache`. The probe stores the key `health_check` with the value `ok` and a 60-second lifetime through the `Cache` port, reads it back and compares.

Likely causes:

- the shipped adapter is the in-process `MokaCache`, which cannot be unreachable, so a failure means the write or the comparison failed: look at `cause` for a cache error or a value mismatch;
- after a service replaced the adapter with an external one (see `docs/extension-seams.md`): the cache server is down, refuses the credentials or is slower than the probe deadline.

Checks:

1. Read the `cause` of the `health probe failed` line with `dependency` equal to `cache`.
2. For an external cache, connect to it from the service's network with its own client and run a write and a read.
3. Check that the adapter's connection and operation timeouts are below `HEALTH_PROBE_TIMEOUT`; configuration validation enforces this for the shipped settings, and a new adapter must keep the rule.

No response of the service depends on cache content, so this failure reports a degraded dependency but loses no data.

### `Message broker is not available`

Wire identifier: `dependency` is `message_broker`. The probe calls `ListQueues` with a result limit of one on the SQS endpoint. The call reads account state and creates nothing; it needs only the permission `sqs:ListQueues`.

Likely causes:

- `AWS_ENDPOINT_URL_SQS` points to an endpoint that is down (in development: the `localstack` container is still starting or stopped) or is blank where the regional endpoint is meant;
- `AWS_REGION` is wrong;
- the credentials are missing, expired or lack `sqs:ListQueues` (in AWS the default credential chain supplies role credentials; locally `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` come from the environment, both set or both unset);
- the network blocks the endpoint, or the call exceeds `SQS_OPERATION_TIMEOUT` (default 2 seconds) or `SQS_CONNECT_TIMEOUT` (default 500 milliseconds).

Checks:

1. Read the `cause` of the `health probe failed` line with `dependency` equal to `message_broker`; it holds the SDK error chain.
2. In development run `docker compose ps` and check that `localstack` is healthy; LocalStack needs 3 to 6 seconds after a cold start.
3. From the service's network run the AWS CLI against the same endpoint, for example `aws sqs list-queues --max-items 1 --endpoint-url "$AWS_ENDPOINT_URL_SQS"`.
4. In AWS check the role policy for `sqs:ListQueues`.

### Several failures at once

When more than one probe fails, `detail` lists all messages in registration order (database, cache, message broker) and `failures` holds one entry for each. Work through each section above independently. A body that contains the message of a healthy dependency is a defect; report it.

### Starting without dependencies

`serve` does not wait for dependencies. With the database and the SQS endpoint down, `/ping` answers at once and `/api/health` answers with the problem document within about 2 seconds, naming both. This is the intended behaviour, not a failure of the service.

## Logs and request ids

`serve` writes one JSON object per line on stdout and nothing else on stdout or stderr. The other commands write plain text. Keys:

| Key | Present | Content |
| --- | --- | --- |
| `timestamp` | always | RFC 3339, UTC, microseconds |
| `level` | always | `ERROR`, `WARN`, `INFO`, `DEBUG` or `TRACE` |
| `message` | always | fixed text from the list below |
| `target` | always | Rust module path, or `audit` for audit entries |
| event fields | per message | flattened into the top level |
| `span` | inside a request | the innermost open span: `{"name":"http.request","http.request.method":…,"http.route":…,"url.path":…,"request_id":…}`, or a span opened inside the request (an SQS call opens its own) |
| `spans` | inside a request | every open span, outermost first; the first element is always the `http.request` span with the `request_id` |

Fixed messages:

| Message | Level | Fields | Meaning |
| --- | --- | --- | --- |
| `invalid configuration` | ERROR | `variable`, `reason` | one entry per problem; `serve` then exits with status 2 |
| `listening` | INFO | `addr`, `env`, `version` | start-up marker |
| `request completed` | INFO | `http.response.status_code`, `duration_ms` | the access log, exactly one per request, `/ping`, 404 and 405 included |
| `request failed` | ERROR | `error` | the error chain behind a 5xx problem |
| `panic` | ERROR | `panic` | message and location; the request gets a 500 problem and the process keeps running |
| `health probe failed` | WARN | `dependency`, `cause` | see the health-probe runbook |
| `event publication failed` | ERROR | `event_name`, `event_id`, `error` | one per failing subscriber, `error` is the whole error chain joined by a colon and a space; the request still succeeds |
| `domain event` | INFO, target `audit` | `event_name`, `event_id`, `aggregate_id`, `occurred_at` | the audit subscriber |
| `shutdown signal received` | INFO | `signal` | start of the shutdown sequence |
| `grace period elapsed, forcing shutdown` | WARN | `grace_period` | `serve` then exits with status 1 |
| `stopped` | INFO | none | `serve` then exits with status 0 |
| `serve failed` | ERROR | `error` | bind or runtime failure; `serve` then exits with status 1 |

Lines written outside a request (start-up, shutdown) carry no request span; the AWS SDK writes a few start-up entries at `debug` level inside spans of its own.

The level filter is `LOG_LEVEL`. It takes `tracing_subscriber::EnvFilter` directives: a level such as `debug`, or per-target levels such as `info,sqlx=warn,audit=info`. An invalid directive is a configuration error. Request and response bodies, request headers other than the request id, and `DATABASE_URL` are never logged.

### Request ids

The header is `x-request-id`. An inbound value is accepted when it matches `^[A-Za-z0-9._-]{1,128}$`; any other value is dropped and a UUID is generated. The id is echoed on every response, including 404, 405, panic and timeout responses, and it is the field `request_id` of the first element of `spans` of every log line of the request, also of the lines written inside a span the request opened (at `debug` level the SQS client writes such lines). To follow one request:

```sh
docker compose logs --no-log-prefix app | jq -c 'select(any(.spans[]?; .request_id == "<id>"))'
```

A client that reports a problem should quote the `x-request-id` of the response; the bug-report template asks for it.

## Shutdown sequence

1. At t = 0 the process receives SIGTERM or SIGINT and logs `shutdown signal received`. The listener closes: new connections are refused within about 10 milliseconds. In-flight requests continue.
2. When the last in-flight request has completed, the process logs `stopped` and exits with status 0. An idle service exits within 2 seconds.
3. At t = `SHUTDOWN_GRACE_PERIOD` (default 10 seconds) with a connection still open, the process logs `grace period elapsed, forcing shutdown` at `WARN`, drops the remaining connections and exits with status 1 within 2 seconds.

An exit status 1 after a deployment therefore means that at least one request was cut off by the end of the grace period. Check the access log for requests that did not log `request completed`, and consider raising `SHUTDOWN_GRACE_PERIOD` or lowering `HTTP_REQUEST_TIMEOUT` (default 10 seconds). A bind failure or runtime failure also exits with status 1 and logs `serve failed`. Status 2 is always an invalid configuration.

Set the orchestrator's termination timeout to at least 15 seconds, so that SIGKILL does not arrive before the grace period ends. The container healthcheck runs `["/app/service", "healthcheck"]` (the image has no shell) every 10 seconds with a timeout of 3 seconds and 3 retries; it probes `/ping` on the address in `APP_HOST` (the loopback address when `APP_HOST` is `0.0.0.0` or `::`, as in the image), so a service bound to one specific address is probed on that address.

## Toolchain update procedure

The Rust toolchain version is held in three places. `make validate-invariants` fails when they differ, and all three are protected configuration:

| Place | What it holds |
| --- | --- |
| `rust-toolchain.toml` | the channel, for every local and CI build |
| `Dockerfile` | the tag (and digest) of the builder image, a literal `FROM` reference |
| `Cargo.toml` | `rust-version` in `[workspace.package]` |

Dependabot opens one pull request for the toolchain file and one for the images. Do not merge them separately: each leaves the three places unequal and fails the invariant gate.

1. Create one branch from `main`.
2. Take the toolchain change of the Dependabot toolchain pull request and the builder-image change (tag and digest) of the Docker pull request, and set `rust-version` to the same version. Close both Dependabot pull requests when yours is open.
3. Review `make/tool-versions.mk` for the new toolchain (see the next section), because Dependabot cannot update that file.
4. Run `make ci`. Fix new compiler or clippy findings; do not weaken a lint or add a suppression to pass.
5. Open one pull request, title `chore(#<issue>): update Rust to <version>`, and ask a maintainer to add the label `approved-config-change`. The change-control job fails without it because the files are protected.
6. Merge with squash. Releases are not triggered by a `chore` commit.

## Tool-version review

Every tool the Make targets and the scripts use has its version, or its image reference with tag and digest, in `make/tool-versions.mk`. Dependabot cannot update this file, so a maintainer reviews it with each toolchain update and at least once a quarter.

CI installs the cargo tools with `taiki-e/install-action`, pinned by commit, with `fallback: none`. A version may therefore be raised only to a version that the file `manifests/<tool>.json` of the pinned install action lists. The pinned commit lists every cargo tool at its pinned version, and `typos` up to 1.52.0.

1. Look up the newest release of the tool and read `manifests/<tool>.json` at the pinned action commit.
2. If the newer version is listed, change it in `make/tool-versions.mk` and in every `tool:` entry of the workflows. `make validate-invariants` fails when a `tool:` entry differs from the file.
3. If it is not listed, first bump the install action (a pull request that changes the pin and its tag comment), then raise the tool.
4. For an image, take the tag and the digest from the registry and keep both in the reference.
5. Run `make ci` and open a pull request with the label `approved-config-change`.

## First measurements

These tables record what the first runs cost, so that later changes can be judged against them. The local values were entered by Story 10.5; the hosted-runner values are those of the first complete pipeline run, on commit `db7fe08` of the bootstrap pull request on 2026-11-11, and of the first run of the scheduled workflow on `main`, on commit `3e0bd3e` on 2026-11-11. The duration of a documentation-only pull request (budget 5 minutes) has not been measured yet: no such pull request has run.

Conditions of the local runs, 2026-11-11: a virtual machine with 4 vCPUs, 15 GB of memory and Linux 6.18, a fresh clone in a temporary directory (project name `service-clone`), no build directory and no compiler cache. Cargo ran with `CARGO_INCREMENTAL=0` and `CARGO_PROFILE_DEV_DEBUG=0` and everything else at its default. The hosted jobs use the same two settings: the pull-request jobs that run cargo on the runner receive both from the toolchain action (`actions-rust-lang/setup-rust-toolchain` sets them), and the scheduled clean-clone job `clean-bootstrap-ci`, which does not use that action, sets both in the `env` of its workflow. The pinned tools were already installed on the machine, so `make bootstrap` did not compile them. Both container images were built beforehand from the same commit and the runs used `BUILD_IMAGE=0`, so the image builds are not part of any duration below. The development image had been built earlier the same day, and its inputs (`make/tool-versions.mk`, `scripts/install-tools.sh`, `scripts/install-bats.sh` and the base image) had not changed since. The machine was shared with other work (load average 3.84 at the start of `make bootstrap`). The commit is `d152806`.

Local runs, on that machine:

| Command | Date | Duration | Budget of the PRD | Budget met | Notes |
| --- | --- | --- | --- | --- | --- |
| `make bootstrap` | 2026-11-11 | 116 s (1 min 56 s) | `GET /ping` within 15 minutes | yes, without tool and image builds (see the conditions) | clean clone, no build directory; `GET /ping` answered 200 right after the command returned; it compiled no tool and built no image (see the conditions) |
| `make ci` | 2026-11-11 | 1482 s (24 min 42 s) | within 45 minutes on 4 vCPUs | yes, without the production image build (see the conditions) | after `make bootstrap`, cold build directory; exit 0, 297 Bats tests, all `ok`; stages below |
| `make start` | 2026-11-11 | 12 s | within 60 s with images and cache present | yes | after the `make ci` run, images and build output present, the stack stopped before |
| `make ci base_ref=HEAD` (Story 10.4, for comparison) | 2026-11-11 | 1575 s (26 min 15 s) | within 45 minutes on 4 vCPUs | yes | warm compiler cache and build directory in the working tree, commit `ecbca71`, 295 Bats tests; this run is not comparable with the cold run above: it used other cargo settings and ran beside other work |
| `make mutation-tests` (Story 9.3, all 8 shards, one after the other) | 2026-11-11 | 339 s to 1146 s per shard, see below | none | not applicable | 665 mutants: 409 caught, 256 unviable, none missed or timed out |
| `npx --yes @devcontainers/cli@0.90.0 build`, the two features of `.devcontainer/devcontainer.json` only (partial) | 2026-11-11 | 79 s | none | not applicable | partial evidence: `build` was replaced by a development image built earlier on this machine (plus the network settings the machine needs), so only the two feature layers were built; common-utils 2.7.1 created the user `dev` (uid and gid 1000, groups `dev` and `docker`) and docker-in-docker 4.1.3 with `moby: false` installed Docker 29.9.3, Compose v2.40.3 and buildx v0.39.0 on Debian trixie; the first full build of the committed definition, by the job `devcontainer-build` of the scheduled run on commit `3e0bd3e` (below), failed in the common-utils feature, which this run did not show because the kernel setting `fs.protected_regular` is 0 on this machine |

The budgets are the ones of the PRD. All three are met by the local runs; no budget, threshold or timeout was changed. The local runs are not a measurement of a cold hosted runner: they excluded the installation of the tools and both image builds (see the conditions). The hosted runs of commit `db7fe08` measured the two image builds, each in a job that starts without any cache (the image caches are saved on `main` only, and `main` had not run these workflows):

| Part excluded locally | Hosted job and step | Duration |
| --- | --- | --- |
| cold build of the development image | `Bats: surface`, build step 16:29:11Z to 16:32:05Z | 2 min 54 s |
| cold build of the production image | `Smoke load tests`, build step 16:28:40Z to 16:32:40Z | 4 min 0 s |

Estimate for a cold hosted runner, from these figures and the local runs (a sum of figures from two machines with 4 vCPUs each, not a measurement): `make bootstrap` about 116 s plus 2 min 54 s, that is about 4 min 50 s, plus the installation of the pinned tools, which no run has measured (budget 15 minutes); `make ci` about 24 min 42 s plus 4 min 0 s, that is about 28 min 42 s (budget 45 minutes). The first run of the scheduled job `clean-bootstrap-ci`, which runs both commands on a clean clone on a hosted runner, measured them and confirms the budgets of both (see the scheduled run below).

Stages of the `make ci` run, from the timestamps of the log (the stage that was running was sampled every 2 s, so each boundary is accurate to about 2 s):

| Stage | Duration |
| --- | --- |
| 1 `ci-preflight` | 50 s |
| 2 `ci-static-analysis` | 3 min 53 s |
| 3 `ci-tests` | 3 min 11 s |
| 4 `ci-contracts` | 28 s |
| 5 `ci-mutation` | 2 s (empty diff, no mutants) |
| 6 `ci-delivery` | 54 s |
| 7 `ci-cli` | 15 min 24 s |
| Total | 24 min 42 s (1482 s) |

The six Bats groups run one after the other inside stage 7, files in alphabetical order. The duration of a test is the time between its result line and the one before it, so the first test of a file also carries its `setup_file`. Each file belongs to the group of its `file_tags` line.

| Group | Tests | Duration |
| --- | --- | --- |
| `surface` | 78 | 6 min 9 s |
| `repository` | 144 | 3 min 0 s |
| `load` | 24 | 2 min 22 s |
| `tests` | 16 | 1 min 53 s |
| `quality` | 24 | 1 min 5 s |
| `contracts` | 11 | 57 s |
| Total | 297 | 15 min 26 s |

The sum is two seconds above the stage because the first Bats line is counted from the start of the command.

Mutation run of Story 9.3 on commit `3650cd4`, on the same machine with its own PostgreSQL and LocalStack, the shards run one after the other with the mutation slot of the machine: 665 mutants in 8 shards of 84 (the last one 77), all of them tested, none missed, none timed out. The duration of a shard from its start to its exit, which includes waiting for a free slot and the unmutated baseline build of the shard itself (339 s for the first shard, falling to 11 s for the last as the build directory warmed):

| Shard | Mutants | Caught | Unviable | Duration |
| --- | --- | --- | --- | --- |
| 0/8 | 84 | 47 | 37 | 1146 s |
| 1/8 | 84 | 38 | 46 | 819 s |
| 2/8 | 84 | 30 | 54 | 556 s |
| 3/8 | 84 | 58 | 26 | 358 s |
| 4/8 | 84 | 30 | 54 | 371 s |
| 5/8 | 84 | 70 | 14 | 433 s |
| 6/8 | 84 | 70 | 14 | 339 s |
| 7/8 | 77 | 66 | 11 | 375 s |

On the bootstrap pull request the hosted workflow counts 697 mutants for commit `d152806` (every file is new against `main`, which holds only the root commit) and divides them into shards of 150, which gives 5 shards. The 665 mutants above belong to the earlier commit `3650cd4`. The durations on 2026-11-11 for commit `d152806` are in the table of the pull-request jobs below. The planning job divides the mutants into shards of 150 (at least 1 and at most 8 shards); that divisor was not changed. The mean time per mutant was not computed: the local shards waited for slots and shared the machine, so a mean from them would not be a stable figure for the divisor.

Smoke load test: the `health` profile ran inside `make ci` (stage 6) with a p99 of 14.79 ms against the budget of 500 ms that `tests/Load/config.json.dist` held at the time of the run. The budget shipped since then is 50 ms, derived from the hosted-runner measurements; a p99 of 14.79 ms is within it (see `docs/load-testing.md`).

Pull-request jobs on a hosted runner, commit `db7fe08` of the bootstrap pull request, 2026-11-11, from the start and end times of the latest check run of each name. No Rust or image cache was restored, because the caches are saved on `main` only, so these are cold figures:

| Job | Date | Duration | Notes |
| --- | --- | --- | --- |
| `format-check` | 2026-11-11 | 17 s | check `Formatting check` |
| `static-analysis` | 2026-11-11 | 2 min 11 s | check `Static analysis` |
| `tests` | 2026-11-11 | 4 min 6 s | check `Tests and coverage` |
| `e2e-tests` | 2026-11-11 | 2 min 38 s | check `End-to-end tests` |
| `mutation-shard` (longest shard) | 2026-11-11 | 11 min 46 s | shard 1/5 of commit `db7fe08`; the other four took 6 min 0 s, 7 min 18 s, 8 min 37 s and 9 min 8 s. Earlier, on commit `d152806`, shard 1/5 took 15 min 32 s and the other four 5 min 28 s, 7 min 32 s, 7 min 49 s and 9 min 0 s |
| `bats-group` (longest group) | 2026-11-11 | 10 min 19 s | group `surface`, which includes the cold build of the development image (2 min 54 s); the other groups took 9 min 0 s (`contracts`), 8 min 38 s (`load`), 7 min 2 s (`tests`), 4 min 41 s (`quality`) and 3 min 56 s (`repository`) |
| `schemathesis` | 2026-11-11 | 4 min 34 s | check `Schemathesis` |
| `smoke-load-tests` | 2026-11-11 | 5 min 21 s | check `Smoke load tests`, which includes the cold build of the production image (4 min 0 s) |
| `image-scan` | 2026-11-11 | 5 min 30 s | check `Production-image scan` |
| `docs-check` | 2026-11-11 | 1 min 41 s | check `Documentation drift` |

The whole pull request on that commit: the first check started at 16:28:08Z, the last check other than the mutation check (`Makefile tests (Bats)`) ended at 16:39:01Z, 10 min 53 s later, and the mutation check (`Mutation tests`) ended at 16:43:53Z, 15 min 45 s after the first start. This is within the cold budget of 40 minutes, the mutation check apart, and within the 45 minutes per shard of the mutation check; the Bats requirement of 20 minutes, read per group because the six groups are separate jobs, is met by the longest group with 10 min 19 s. The warm budget of 20 minutes is measured on the first pull request after a push to `main` has saved the caches.

Scheduled run on a hosted runner: run 43107219243 of the workflow `Scheduled verification`, started by hand (`workflow_dispatch`) on `main` after the merge of the bootstrap pull request, commit `3e0bd3e`, 2026-11-11, on GitHub-hosted runners with the label `ubuntu-24.04`. The job `Clean bootstrap and make ci` (`clean-bootstrap-ci`) restores no cache (its log does not show the number of CPUs of the runner); its `make bootstrap` installed the pinned tools, built the development image and started the stack. Durations from the start and end times of the steps and of the job:

| Step of `clean-bootstrap-ci` | Duration | Budget of the PRD | Budget met | Notes |
| --- | --- | --- | --- | --- |
| `Bootstrap` (`make bootstrap`) | 447 s (7 min 27 s) | `GET /ping` within 15 minutes | yes | the application container reported healthy at the end of the step; its health check sends `GET /ping` |
| `Run every gate` (`make ci`) | 1828 s (30 min 28 s) | within 45 minutes | yes | exit 0, 378 Bats tests, all `ok` |
| `Require a clean working tree` | 0 s (start and end in the same second) | none | not applicable | passed: the two commands left the working tree unchanged |
| the whole job | 2294 s (38 min 14 s) | none | not applicable | from the start to the end of the job |

This run confirms the budgets of NFR35 for `make bootstrap` (15 minutes) and `make ci` (45 minutes) on a hosted runner, from a clean clone with no restored cache and no manual step (NFR34). The budget of `make start` with images and build output present is measured on the local machine only (12 s, above).

The mutation shards of the same run ran `make mutation-tests` over the whole workspace in 5 shards; every shard and the job `Mutation tests` passed: 699 mutants, 459 caught, 240 unviable, none missed or timed out. The duration is that of the job:

| Shard | Mutants | Caught | Unviable | Duration |
| --- | --- | --- | --- | --- |
| 0/5 | 140 | 58 | 82 | 9 min 17 s |
| 1/5 | 140 | 92 | 48 | 15 min 36 s |
| 2/5 | 140 | 72 | 68 | 7 min 6 s |
| 3/5 | 140 | 116 | 24 | 8 min 46 s |
| 4/5 | 139 | 121 | 18 | 8 min 19 s |

The job `Development container build` (`devcontainer-build`) of the same run failed after 2 min 55 s. The `dev` stage of the `Dockerfile` built; the common-utils feature then stopped with `/home/dev/.bashrc: Permission denied`, because the `dev` stage gave the home directory the sticky bit and the runner's kernel refuses root an append to a file of another user in such a directory (`fs.protected_regular`). The `Dockerfile` now gives the home directory mode `0777` without the sticky bit; the build of the fixed definition has not yet run on a hosted runner.

## Accepted findings: `.trivyignore` and `.gitleaksignore`

A finding of a scanner is fixed, not accepted, unless no fix exists. An accepted finding is an entry with a date, a reason and a review date, so that nothing stays accepted without a decision.

`.trivyignore` lists vulnerability identifiers for the image scan (`make image-scan`, severities HIGH and CRITICAL). One identifier per line, with the comment lines directly above it:

```text
# 2026-11-10: libexample 1.2.3 in the runtime layer; no fixed package exists yet.
# The vulnerable function is not reachable from the service. Review by 2027-02-10.
CVE-2026-00000
```

`.gitleaksignore` lists fingerprints of accepted secret-scan findings, one fingerprint per line, with a dated comment above it. Take the fingerprint from the finding that `make secrets-scan` prints (`<commit>:<file>:<rule>:<line>` for a history finding, `<file>:<rule>:<line>` for a working file):

```text
# 2026-11-10: documented example token in an example file, not a credential. Review by 2027-02-10.
config/example.txt:generic-api-key:42
```

Rules for both files:

1. Add an entry only in a pull request that states why the finding cannot be fixed. A real secret is never accepted: revoke and rotate it, then remove it from the history.
2. Every entry carries the date of acceptance, the reason and the review date. The review date is at most three months away.
3. When the review date has passed, either remove the entry (the finding is fixed) or renew it with a new date and reason.
4. Both files belong to the service after a repository is created from the template, and template sync ignores them.
