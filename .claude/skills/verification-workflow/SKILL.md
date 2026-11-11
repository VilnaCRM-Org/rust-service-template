---
name: verification-workflow
description: Use when running the repository checks or fixing a failing gate before declaring a change complete.
---

# Verification Workflow

## Use This Skill When

- A change is ready and must be proven before it is called complete.
- A gate fails and the owning skill must be found.

## Commands

- `make ci` runs every gate in order and prints `CI checks successfully passed!`; it stops at the first failure.
- `make ci-list` prints the gate targets of `make ci`; the same list is the block in the [verification section](../../../AGENTS.md#verification) of `AGENTS.md`, which this skill never repeats.
- The stages can be run alone, in this order:
  - `make ci-preflight`
  - `make ci-static-analysis`
  - `make ci-tests`
  - `make ci-contracts`
  - `make ci-mutation`
  - `make ci-delivery`
  - `make ci-cli`

## Rules

- Run the narrowest stage that covers the change while iterating, and `make ci` before declaring completion.
- Fix the root cause of a failing gate; never edit a protected file to obtain a pass (see `quality-standards`).
- Find the owner of a failure by stage:
  - preflight, repository lint and configuration guard: `documentation-sync`, `quality-standards`;
  - formatting, lint and complexity: `complexity-management`;
  - architecture, dependency and manifest checks: `architecture-boundary-fixer`;
  - documentation drift: `documentation-sync`;
  - model validation: `architecture-model-sync`;
  - tests, coverage and mutation: `testing-workflow`;
  - contract snapshots, lint, diffs and conformance: `api-contract-development`;
  - smoke load: `load-testing`.
- A documentation-only change runs the repository lint and the drift check; say so in the close-out.
- Close-out wording: list the targets that were run with their result, the targets that were not run with the reason, and every gate that stayed red with its cause.
- Never claim a target passed that was not run.

## Verification

```bash
make ci-list
```

Pick the skill named above for the failing stage; `quality-standards` lists every gate.
