---
name: api-resource-development
description: Use when adding or changing a REST or GraphQL operation, a command, a query, an event subscriber or a migration of a bounded context.
---

# API Resource Development

## Use This Skill When

- A REST endpoint, GraphQL field, command, query, event subscriber or migration is added or changed.
- A new bounded context is needed for a new resource.

## Commands

- `make new-context group=<group> context=<context>` creates the three crates of a context.
- `make create-migration name=<snake_case_description>` creates a reversible migration pair.
- `make migrate` applies pending migrations to the development database.
- `make sqlx-prepare` refreshes `.sqlx/` after a query or migration changes.
- `make generate-openapi-spec` and `make generate-graphql-spec` refresh the contract snapshots.
- `make unit-tests` and `make e2e-tests` prove the behaviour.

## Rules

- Copy the shape of the example slice under `crates/company-subdomain/some-module/`:
  - domain, in `domain/src/`: `aggregate.rs`, `event.rs`, `error.rs`, `repository.rs`, `value_object/`;
  - application, in `application/src/`: `command/`, `query/`, `subscriber/`, `http/dto.rs`, `http/handler.rs`, `graphql.rs`, `error.rs`;
  - infrastructure, in `infrastructure/src/`: `persistence.rs`, with its integration tests under `infrastructure/tests/integration/`.
- Follow the recipes of the core architecture document (section "Recipes"): add a REST endpoint, a GraphQL field, a command, a query, an event subscriber, a migration, a bounded context.
- Extract request data with `ApiPath`, `ValidatedQuery`, `ValidatedJson` or `ApiJson` only; bare `Path`, `Query` and `Json` answer with plain text errors.
- Commands return no data: generate the id before dispatch and read the result through a query.
- A handler gets a unit test with `FakeCommandBus` or `FakeQueryBus`, and a scenario goes into a file under `features/`.
- Register new handlers in `service::bootstrap::router` and new subscribers in `service::bootstrap::event_bus`.
- Never edit a migration that has reached `main`; add a new one.
- Regenerate both contract snapshots in the same change as the code.

## Verification

```bash
make unit-tests
make e2e-tests
```

Continue with `api-contract-development` for the snapshots, `testing-workflow` for failing tests and `architecture-model-sync` when a crate was added.
