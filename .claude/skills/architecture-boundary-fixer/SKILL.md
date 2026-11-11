---
name: architecture-boundary-fixer
description: Use when `make architecture` reports a violation or code must move between layers or bounded contexts.
---

# Architecture Boundary Fixer

## Use This Skill When

- `make architecture` exits with a violation.
- Code has to move between layers or between bounded contexts.

## Commands

- `make architecture` runs the boundary check; exit status 1 means violations, 2 means it could not run.
- `make unused-dependencies` finds declared dependencies that no code uses.
- `make validate-manifest` checks that `Cargo.lock` matches the manifests.

## Rules

- Never edit `architecture.toml` to obtain a pass; it is protected. Fix the code.
- Fix patterns, one per rule of the diagnostic:
  - `arch::uncovered`: rename the crate to match one layer pattern, for example `<context>-domain`.
  - `arch::ambiguous`: rename the crate so that exactly one layer pattern matches.
  - `arch::layer`: remove the dependency on the forbidden layer; define a port trait in the inner layer and implement it in the outer one.
  - `arch::context`: remove the dependency on the other context; communicate through a domain event or a shared-kernel type in `crates/shared/`.
  - `arch::external`: remove the third-party crate from the layer; wrap it behind a port in infrastructure, or move the code to the layer that may use it.
  - `arch::transitive`: find the dependency that pulls the forbidden crate in with `cargo tree -i <crate>` and remove or replace it.
  - `arch::path`: move the crate to `crates/[<group>/]<context>/<layer>` and update the workspace member list.
  - `arch::lints`: add `[lints]` with `workspace = true` to the crate manifest.
- Keep Domain crates free of framework code; serde, utoipa, sqlx and axum belong to outer layers.
- After moving code, remove dependencies the old crate no longer needs.
- A new context or crate also changes `workspace.dsl`.

## Verification

```bash
make architecture
make unused-dependencies
```

Continue with `architecture-model-sync` when crates changed and with `api-resource-development` when a slice was restructured.
