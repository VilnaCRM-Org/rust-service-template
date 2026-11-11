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

`GET /api/health` answers `204` with an empty body when every probe succeeds. Otherwise it answers `500` with a problem document of type `/problems/dependency-unavailable`. Its `failures` member holds one entry per failing dependency, and `detail` joins the messages with a semicolon and a space. The messages are fixed and identical in every environment. The underlying cause is never returned: it is a log line `health probe failed` at `WARN` with the fields `dependency` and `cause`, and it carries the request id of the probe request.

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
| `span` | inside a request | `{"name":"http.request","http.request.method":…,"http.route":…,"url.path":…,"request_id":…}` |

Fixed messages:

| Message | Level | Fields | Meaning |
| --- | --- | --- | --- |
| `invalid configuration` | ERROR | `variable`, `reason` | one entry per problem; `serve` then exits with status 2 |
| `listening` | INFO | `addr`, `env`, `version` | start-up marker |
| `request completed` | INFO | `http.response.status_code`, `duration_ms` | the access log, exactly one per request, `/ping`, 404 and 405 included |
| `request failed` | ERROR | `error` | the error chain behind a 5xx problem |
| `panic` | ERROR | `panic` | message and location; the request gets a 500 problem and the process keeps running |
| `health probe failed` | WARN | `dependency`, `cause` | see the health-probe runbook |
| `event publication failed` | ERROR | `event_name`, `event_id`, `error` | one per failing subscriber; the request still succeeds |
| `domain event` | INFO, target `audit` | `event_name`, `event_id`, `aggregate_id`, `occurred_at` | the audit subscriber |
| `shutdown signal received` | INFO | `signal` | start of the shutdown sequence |
| `grace period elapsed, forcing shutdown` | WARN | `grace_period` | `serve` then exits with status 1 |
| `stopped` | INFO | none | `serve` then exits with status 0 |
| `serve failed` | ERROR | `error` | bind or runtime failure; `serve` then exits with status 1 |

Lines written outside a request (start-up, shutdown) carry no `span`.

The level filter is `LOG_LEVEL`. It takes `tracing_subscriber::EnvFilter` directives: a level such as `debug`, or per-target levels such as `info,sqlx=warn,audit=info`. An invalid directive is a configuration error. Request and response bodies, request headers other than the request id, and `DATABASE_URL` are never logged.

### Request ids

The header is `x-request-id`. An inbound value is accepted when it matches `^[A-Za-z0-9._-]{1,128}$`; any other value is dropped and a UUID is generated. The id is echoed on every response, including 404, 405, panic and timeout responses, and it is the field `request_id` in the `span` of every log line of the request. To follow one request:

```sh
docker compose logs app | jq -c 'select(.span.request_id == "<id>")'
```

A client that reports a problem should quote the `x-request-id` of the response; the bug-report template asks for it.

## Shutdown sequence

1. At t = 0 the process receives SIGTERM or SIGINT and logs `shutdown signal received`. The listener closes: new connections are refused within about 10 milliseconds. In-flight requests continue.
2. When the last in-flight request has completed, the process logs `stopped` and exits with status 0. An idle service exits within 2 seconds.
3. At t = `SHUTDOWN_GRACE_PERIOD` (default 10 seconds) with a connection still open, the process logs `grace period elapsed, forcing shutdown` at `WARN`, drops the remaining connections and exits with status 1 within 2 seconds.

An exit status 1 after a deployment therefore means that at least one request was cut off by the end of the grace period. Check the access log for requests that did not log `request completed`, and consider raising `SHUTDOWN_GRACE_PERIOD` or lowering `HTTP_REQUEST_TIMEOUT` (default 10 seconds). A bind failure or runtime failure also exits with status 1 and logs `serve failed`. Status 2 is always an invalid configuration.

Set the orchestrator's termination timeout to at least 15 seconds, so that SIGKILL does not arrive before the grace period ends. The container healthcheck runs `["/app/service", "healthcheck"]` (the image has no shell) every 10 seconds with a timeout of 3 seconds and 3 retries; it probes `/ping`.

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

These tables record what the first runs cost, so that later changes can be judged against them. The values are entered once the first complete run exists (Story 10.5 enters the local values; the hosted-runner values follow the first pipeline run). An empty cell means that nothing has been measured yet.

Local runs, on one named machine:

| Command | Machine (CPU cores, memory, OS) | Date | Duration | Notes |
| --- | --- | --- | --- | --- |
| `make bootstrap` | | | | clean clone, no cache |
| `make ci` | | | | after `make bootstrap` |
| `make mutation-tests` | | | | number of mutants, seconds per mutant |

Mutation run: the first full run on `main` also records the number of mutants, the mean seconds per mutant and the time of each shard, because the planning job divides the mutants into shards of 150 (at least 1 and at most 8 shards) and the divisor is revised from that measurement.

Pull-request jobs on a hosted runner:

| Job | Date | Duration | Notes |
| --- | --- | --- | --- |
| `format-check` | | | |
| `static-analysis` | | | |
| `tests` | | | |
| `e2e-tests` | | | |
| `mutation-shard` (longest shard) | | | |
| `bats-group` (longest group) | | | |
| `schemathesis` | | | |
| `smoke-load-tests` | | | |
| `image-scan` | | | |
| `docs-check` | | | |

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
