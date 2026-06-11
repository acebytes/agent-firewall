# Contributing

This project's main purpose is keeping a set of **empirically ratified** invariants current against real Claude Code releases. Contributions are most welcome when they extend that guarantee.

## Kinds of contribution we want

1. **New experiments** that ratify additional invariants — see [`docs/ADDING-EXPERIMENTS.md`](docs/ADDING-EXPERIMENTS.md).
2. **Regression captures.** When CI goes red on a new Claude Code release, a PR that (a) describes the behavior change and (b) adds a failing baseline is more valuable than silently patching the experiment.
3. **Adapter ports.** Right now the harness targets `@anthropic-ai/claude-code`. Ports that reuse the same invariant framework against other hook-capable agents (Codex, aider, etc.) are interesting as sibling projects.
4. **Shim/enforcer hardening.** The Go reference shim in `shim/` and the reference enforcer in `enforcer/` are intentionally minimal. Tightening timer margins, improving NDJSON backpressure, fixing race conditions — all welcome.

## What we're less interested in

- **"Nicer" agent-prose assertions.** The discipline of this harness is that every pass criterion is mechanical (NDJSON grep, sentinel absence, field equality). Grepping agent output tends to break on the next Claude Code release and teaches the wrong lesson.
- **Moving to a different agent framework.** Keep this repo Claude-Code-focused. If you want a different agent, fork.
- **Feature-creep in the enforcer.** `enforcer/` exists to be a credible reference implementation, not a production policy engine. The downstream project that inspired this harness has its own.

## PR checklist

- [ ] New experiments produce the same exit code across two local runs (flakes gets rejected).
- [ ] If the PR adds or modifies an invariant, [`docs/INVARIANTS.md`](docs/INVARIANTS.md) is updated in the same PR.
- [ ] `./run.sh rebuild` passes locally against `@latest`, or the PR body explains why the failure is expected.
- [ ] CI across `@latest`, `@2`, `@1` is green OR the PR body notes a drift the experiment is capturing.
- [ ] No agent-prose-only assertions (see above).

## Style

- Bash scripts: `set -u`, but not `set -e` — we want to see the exit code of the `claude` invocation, not abort on it.
- Go sources: `gofmt`. Vendor dependencies to keep the Docker build deterministic.
- YAML: two-space indent, no trailing whitespace.

## Licensing

By contributing, you agree your contribution is licensed under the MIT license in `LICENSE`. Keep copyright notices intact.

## Conduct

Be kind. Critique experiments, not people. If you find a blocker, open an issue before a PR so we can discuss the test shape.
