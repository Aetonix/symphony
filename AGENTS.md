# Symphony Elixir

This directory contains the Elixir agent orchestration service that polls a tracker, creates per-issue workspaces, and runs the agent named by `WORKFLOW.md` over ACP. This build registers the Cursor implementer (`agent acp`).

## Environment

- Elixir: `1.19.x` (OTP 28) via `mise`.
- Install deps: `mix setup`.
- Main quality gate: `make all` (format check, lint, coverage, dialyzer).


## Codebase-Specific Conventions

- Runtime config is loaded from `WORKFLOW.md` front matter via `SymphonyElixir.Workflow` and `SymphonyElixir.Config`.
- Prefer adding config access through `SymphonyElixir.Config` instead of ad-hoc env reads.
- Workspace safety is critical:
  - Never run an agent prompt cwd in the source repo.
  - Workspaces must stay under configured workspace root.
- Orchestrator behavior is stateful and concurrency-sensitive; preserve retry, reconciliation, and cleanup semantics.
- Simplicity is a project constraint: prefer the smallest coherent design with one clear owner and
  invariant. Push back on extra abstractions, duplicated policy, and speculative flexibility.
- For stateful changes, check startup, reload, restart, and failure recovery together before editing.
- Follow `docs/logging.md` for logging conventions and required issue/session context fields.
- Agent skills that Symphony gives the agents it spawns live in `priv/skills`. `SymphonyElixir.Skills`
  embeds them at compile time and installs them on startup, so changes there ship with the build.

## Tests and Validation

Run targeted tests while iterating, then run full gates before handoff.

- Prefer narrow tests that exercise real OTP processes and observable behavior over mock-only or
  broad end-to-end coverage; prove health with a synchronous call or stable effect, not only a PID.
- For non-trivial changes, use an adversarial review early to challenge complexity and try to break
  adjacent lifecycle paths; a reproducible failure blocks landing even if other reviews are clean.
- If tests need repeated global restarts or bespoke cleanup, first fix the shared harness or
  ownership boundary.

```bash
make all
```

## Required Rules

- Public functions (`def`) in `lib/` must have an adjacent `@spec`.
- `defp` specs are optional.
- `@impl` callback implementations are exempt from local `@spec` requirement.
- Evaluate proposed directions instead of agreeing reflexively; surface simpler designs and material
  trade-offs early.
- Keep changes narrowly scoped; avoid unrelated refactors.
- Follow existing module/style patterns in `lib/symphony_elixir/*`.

Validation command:

```bash
mix specs.check
```

## Docs Update Policy

If behavior/config changes, update docs in the same PR:

- `README.md` for project concept, goals, and run instructions.
- `WORKFLOW.md` for workflow/config contract changes.
