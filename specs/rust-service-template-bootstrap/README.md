# Rust Service Template Bootstrap — Planning Specs

Planning bundle for bootstrapping `rust-service-template` as the
Rust-ecosystem counterpart of
[`php-service-template`](https://github.com/VilnaCRM-Org/php-service-template).
It was produced with BMAD-METHOD through bmalph, run autonomously: one focused
subagent per stage, independent validators after each planning artifact, and
the orchestrating agent acting as the user's surrogate for decisions.

## Artifacts

| Phase | BMAD command | Artifact | Status |
| --- | --- | --- | --- |
| 1. Analysis | `analyst`, `technical-research` | [Research digest](research.md) | Complete |
| 1. Analysis | `analyst` | [Capability catalog](capability-catalog.md) | Complete |
| 1. Analysis | `create-brief` | [Product brief](product-brief.md) | Complete |
| 2. Planning | `create-prd`, `validate-prd`, `edit-prd` | [PRD](prd.md) | Complete |
| 3. Solutioning | `create-architecture`, `validate-architecture` | [Architecture: core](architecture.md) | Complete |
| 3. Solutioning | `create-architecture`, `validate-architecture` | [Architecture: delivery](architecture-delivery.md) | Complete |
| 3. Solutioning | `create-epics-stories`, `validate-epics-stories` | Epics and stories | In validation |
| 3. Solutioning | `implementation-readiness` | Implementation readiness | Pending |
| — | orchestrator | [Scope decisions](scope-decisions.md) | Living record |
| — | orchestrator | Run summary | Pending |

## How to read the bundle

1. [Scope decisions](scope-decisions.md) — what is in scope, what is not, and
   every decision taken on the maintainers' behalf. Start here if you want to
   overrule something.
2. [Research digest](research.md) — what the PHP template really contains,
   what its enterprise audit found, which Rust tools replace which PHP tools
   (with the versions that were built and run), and the pitfalls found by
   running them.
3. [Capability catalog](capability-catalog.md) — every PHP-template capability
   with its disposition (keep, fix, extend, drop) and the contracts to
   preserve. The PRD traces to these ids.
4. [Product brief](product-brief.md) and [PRD](prd.md) — users, journeys,
   functional and non-functional requirements, quality gates.
5. [Architecture: core](architecture.md) — workspace and crates, the 27
   architecture decisions, signatures, API contract, data, configuration,
   quality-gate commands and test architecture.
6. [Architecture: delivery](architecture-delivery.md) — Make command surface,
   containers and compose, CI workflows, release, hooks, load testing, Bats,
   AI guidance and the repository file manifest.

## Notes

- The nine raw research reports (five PHP inventories, four Rust technical
  reports) and the spike sources are working material and are not tracked;
  the research digest stands in for them. References such as
  `research/php-*.md` and `research/rust-*.md` point to those local files.
- The generated BMAD and Ralph assets (`_bmad/`, `.ralph/`, `_bmad-output/`)
  stay out of git; see `.gitignore`.
