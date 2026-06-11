# Adding a new experiment

This harness treats each experiment as a falsifiable prediction about Claude Code's `PreToolUse` hook contract. The goal is **mechanical pass/fail** — no grepping for agent prose that drifts across versions, no eyeballing logs.

## Anatomy of a good experiment

Every passing experiment has:

1. **One hypothesis, one pass criterion.** If you find yourself writing "passes if A AND B AND also roughly C", split it into multiple experiments.
2. **A mechanical pass criterion.** NDJSON field equality, `grep -c` on a structured sink, or explicit verdict inspection — not "the agent mentioned X".
3. **Idempotent setup/teardown.** Experiments run in CI hundreds of times. Use EXIT traps to restore `settings.json`, kill side-spawned processes, remove `/tmp/*-canary` sentinels.
4. **A sentinel file, not agent output.** `touch /tmp/exp-NN-canary` inside the blocked command; pass = sentinel **absent**. This survives any LLM output drift.
5. **Round-robin immunity.** Don't depend on state from a prior experiment. Each script starts from a clean enforcer audit sink.

## File layout

```
harness/experiment-NN-<slug>.sh     # the script itself
results/expNN-<slug>.log            # created by the runner
results/enforcer.ndjson             # shared NDJSON audit sink for machine-readable assertions
```

The experiment number is two digits. Slugs are lowercase kebab-case, descriptive enough to read in a summary table.

## Skeleton

```bash
#!/usr/bin/env bash
# experiment-NN-<slug>.sh
#
# Hypothesis: <one sentence>
# Pass criterion: <NDJSON grep / field equality / sentinel absence>
# Invariant under test: INV-NN (see docs/INVARIANTS.md)

set -u
RESULTS="${RESULTS:-/home/tester/harness/results}"
NDJSON="$RESULTS/enforcer.ndjson"
CANARY="/tmp/expNN-canary"
rm -f "$CANARY"

# Snapshot the NDJSON line count before the trial so we can scope the
# assertion to events produced by this experiment only.
BEFORE=$(wc -l <"$NDJSON" 2>/dev/null || echo 0)

trap '<restore any settings.json edits, kill any backgrounded processes>' EXIT

# Invoke Claude Code with the scenario under test.
claude --dangerously-skip-permissions \
  --append-system-prompt "" \
  -p "create the file ${CANARY} using Bash" \
  >"$RESULTS/expNN.log" 2>&1 || true

AFTER=$(wc -l <"$NDJSON")
SCOPED=$(tail -n $((AFTER - BEFORE)) "$NDJSON")

# Pass criterion (mechanical).
if [ ! -e "$CANARY" ] \
   && echo "$SCOPED" | grep -q '"tool":"Bash".*"decision":"deny"'; then
  echo "PASS: expected deny observed, sentinel absent"
  exit 0
fi

echo "FAIL: canary=$([ -e "$CANARY" ] && echo present || echo absent)"
echo "$SCOPED" | head -20
exit 1
```

## NDJSON audit schema (v=1, frozen)

Every experiment can assume the following fields in every NDJSON line:

| field | type | meaning |
|-------|------|---------|
| `v` | int | schema version, currently `1` |
| `ts` | RFC-3339 string | event timestamp |
| `session_id` | string | Claude Code session id; distinguishes parent from subagent |
| `tool` | string | `Bash`, `Write`, `Agent`, `mcp__server__tool`, etc. |
| `mode` | string | `default` / `bypassPermissions` / `plan` / `acceptEdits` |
| `cap` | string | free-form policy label from `settings.env.*` |
| `summary` | string | per-tool payload summary (`cmd=...`, `path=...`, `url=...`, `query=...`) |
| `decision` | string | `allow` / `deny` / `ask` / `defer` |
| `rule` | string | the rule id that matched |
| `latency_us` | int | enforcer-side round-trip in microseconds |
| `audit_id` | string | uuid per decision |

Assertions should filter on `session_id` when the experiment spawns multiple sessions; otherwise scope by NDJSON line-count diff (BEFORE/AFTER).

## Register the experiment

Append the script path to `harness/run-experiments.sh`. The runner invokes each in order and accumulates `results/summary.txt` with the exit codes.

## Baseline and document

1. Run the full sweep at least twice on different days; keep baselines in `results/_baselines/YYYY-MM-DD-roundN-*`.
2. If the experiment ratifies a new invariant, add it to [`INVARIANTS.md`](INVARIANTS.md) with its round number and experiment citation.
3. If it refines an existing invariant, link the new experiment into that section and update the Evidence line.

## Anti-patterns to avoid

- **Grepping agent prose.** "The agent said 'blocked'" is fragile. Agent phrasing shifts between Claude Code releases. Only NDJSON is stable.
- **Multiple claims per experiment.** If one assertion fails, you can't tell which hypothesis broke. Split.
- **Shared state across experiments.** Every run starts fresh; don't rely on a prior script's side effects.
- **Non-deterministic timings.** If you need to test timing (INV-02), use both wall-clock bounds AND a sentinel-absence check. Either on its own is ambiguous.
- **Skipping the clean-up trap.** A failed run that leaves `settings.json` mutated will poison every downstream experiment.

## Invariant ownership

An experiment can test:
- **Positive invariant** — the claim should hold. Pass = it holds.
- **Negative invariant** — the claim about Claude Code's behavior is what it is (e.g. INV-02: outer timeout is fail-open). These experiments may be "red by design" — they document behavior we can't change. Mark them clearly in the script header and `run-experiments.sh` summary.

Exp 03 is the canonical red-by-design experiment; Exp 13 is the positive counterpart proving the shim's internal timer closes the gap.

## Matrix notes

The CI matrix (`.github/workflows/conformance.yml`) runs every experiment against Claude Code `@latest`, `@2.x`, `@1.x`. If your experiment depends on a field that only exists in 2.x+, gate it with a `claude --version` check and exit `77` (skip) on older runtimes — the aggregator treats `77` as neither pass nor fail.
