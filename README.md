# claude-code-hook-conformance

A reproducible, versioned conformance harness for the Claude Code `PreToolUse` hook contract.

Sixteen experiments exercise the hook system end-to-end — from `--dangerously-skip-permissions` immunity to `updatedInput` rewrites to cap-level settings propagation — and ratify **twelve empirically verified invariants** that you can build safety systems on top of.

## Why this exists

Building a safety-critical layer on top of Claude Code means relying on documented hook behavior. But documented behavior and actual behavior drift, versions change, and phrasing in agent output (which many naive tests grep for) shifts. This harness catches drift within hours of a new release:

- **Multi-version CI matrix.** Runs against `@latest`, `@2.x`, `@1.x` on every commit and nightly.
- **Structured NDJSON audit trail.** Machine-readable regression diffs, not just human logs.
- **Microsecond latency measurements.** Per-request granularity, p50/p99/max tracked round-over-round.
- **500-trial randomized fuzzer.** Statistical invariants beyond single-shot payload testing.
- **12 named invariants** (INV-01 through INV-12) with stable IDs that you can cite from your own code.

## Quick start

Requires Docker. Add your `ANTHROPIC_API_KEY` to `.env` and run:

```bash
./run.sh rebuild
```

Expected runtime: 12–15 min on an M-series Mac. Expected result: 14/16 passing, with one (exp 03) red by design, documenting a fail-open behavior in Claude Code's outer hook-timeout.

## The 12 invariants

Full reference in [`docs/INVARIANTS.md`](docs/INVARIANTS.md). Highlights:

| ID | Statement |
|----|-----------|
| INV-01 | PreToolUse hooks fire under `--dangerously-skip-permissions`. |
| INV-02 | Outer hook-timeout is fail-open; internal shim timer is required. |
| INV-03 | `managed-settings.json` overrides user settings. |
| INV-04 | MCP tools match `mcp__<server>__<tool>`. |
| INV-05 | Subagent `Agent` dispatch is subject to parent's hooks. |
| INV-06 | No separate `ConfigChange` event — self-tamper surfaces as `Write`. |
| INV-07 | Cap inheritance `set`/`extend`/`remove` composes correctly. |
| INV-08 | Under bypass, `ask` verdicts act as deny. |
| INV-09 | `updatedInput` rewrites execute; agent sees the rewritten result. |
| INV-10 | `additionalContext` teaching persists across `--resume`d turns. |
| INV-11 | `settings.json.env.*` propagates to hook-subprocess env. |
| INV-12 | `permissionMode` field carries Claude Code's mode verbatim. |

## Repository layout

```
claude-code-hook-conformance/
├── Dockerfile              # self-contained multi-stage build
├── run.sh                  # host bootstrap (./run.sh rebuild | shell | clean)
├── shim/                   # Go reference hook shim (fail-closed internal timer)
├── enforcer/               # Go reference enforcer (rule engine + NDJSON audit)
├── harness/                # 16 experiments + orchestrator
├── docs/
│   ├── INVARIANTS.md       # the 12 named invariants with evidence
│   └── ADDING-EXPERIMENTS.md
├── .github/workflows/
│   └── conformance.yml     # multi-version CI matrix
└── results/                # per-run artifacts (summary.txt, *.log, enforcer.ndjson)
```

## Using the invariants in your own project

Cite invariants in your code with a stable tag:

```swift
// INV-02 — outer hook-timeout is fail-open; shim MUST fail-closed with internal timer
let internalDeadline = Date().addingTimeInterval(9.0)
```

If CI starts failing on a version, check `docs/INVARIANTS.md` — the claim and the failing experiment ID will tell you exactly which assumption broke.

## Extending

See [`docs/ADDING-EXPERIMENTS.md`](docs/ADDING-EXPERIMENTS.md). The short version:

1. Design a falsifiable prediction with a mechanical pass criterion (NDJSON grep, not agent-prose grep).
2. Add `harness/experiment-NN-<slug>.sh`.
3. Run the full sweep; baseline for at least 2 independent runs.
4. Add the invariant to `docs/INVARIANTS.md` with the experiment citation.

## Attribution

Originally extracted from the UserLayerDesktop enforcement proof-of-concept (April 2026). MIT-licensed for any downstream use — rebrand the binaries and env vars to your taste.

## License

MIT. See `LICENSE`.
