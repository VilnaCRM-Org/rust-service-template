---
name: documentation-sync
description: Use when a change affects a command, an environment variable, an endpoint, a workflow or the guidance.
---

# Documentation Sync

## Use This Skill When

- A Make target, a `service` command or an environment variable is added, renamed or removed.
- An endpoint, a workflow, a skill or an entry file changes.

## Commands

- `make docs-check` runs the drift check over every tracked Markdown file.
- `make lint-repo` lints Markdown, YAML, shell, spelling and the rest of the repository files.

## Rules

- Update the surface in the same change as its trigger:
  - a Make target: `docs/make-targets.md` (and `make help` through the target's help text);
  - an environment variable: `docs/environment.md`;
  - an endpoint or GraphQL field: `docs/requests.http`, the contract snapshots and the example in `README.md` when it shows one;
  - a workflow or repository setting: `docs/repository-settings.md` and `CONTRIBUTING.md`;
  - an operational procedure: `docs/operations.md` or `docs/troubleshooting.md`;
  - a skill: the entry in `.claude/skills/README.md`, the only skill inventory;
  - the entry files `AGENTS.md` and `CLAUDE.md`: keep rules in `AGENTS.md` only.
- The drift check fails when a cited Make target, command, slash command or path does not exist, when the verification block of `AGENTS.md` differs from `make ci-list`, when a variable is missing from `docs/environment.md`, or when a skill lacks a name, a description or an index entry.
- Cite the verification list by link to the verification section of `AGENTS.md`; never copy it, and never put more than two gate targets in one fenced block or numbered list.
- Write guidance without the repository name; downstream services rename the checkout.
- State thresholds only in `quality-standards`.

## Verification

```bash
make docs-check
make lint-repo
```

Continue with `verification-workflow` for the close-out and `quality-standards` when a gate or threshold is mentioned.
