#!/usr/bin/env bash
# Experiment 13 — does the Go ul-hook's internal timer fire BEFORE
# Claude Code's outer hook-timeout kills the process?
#
# This is the round-3 follow-up to exp-03 (round-1/round-2 finding that
# Claude's outer hook-timeout is fail-open). Round 1 used a bash
# sleep-30s stub to prove the outer timeout is insufficient; round 3
# proves the real Go shim's internal timer closes the gap.
#
# Setup:
#   1. Start a second mock-enforcer with --hang (sleeps 30s before
#      responding) on a DIFFERENT socket than the default enforcer.
#   2. Point `settings.env.UL_SOCKET` at the hang socket.
#   3. Invoke one Bash call; the real ul-hook (not a stub) will
#      connect, the hang enforcer won't respond, ul-hook's internal
#      UL_TIMEOUT_MS=9000 MUST fire before Claude's outer timeout=10,
#      and ul-hook MUST exit 2 (deny).
#
# ROUND-5 REFACTOR
# ────────────────
# Previous pass criterion required BOTH `canary_absent` AND prose-regex
# `denial_matched`. Prose drift across CLI versions would flip this
# test red even when the timer fired correctly. Ported to emit TAP
# sub-rows for three independent signals:
#
#   1. filesystem canary absent           ← strongest ground truth
#   2. shim log "internal timeout" marker ← ground truth from the shim
#   3. prose hint in model output         ← diagnostic only
#
# Test passes if the two side-channel signals (1 + 2) are both green.
# Prose is reported but doesn't gate pass/fail.
#
# This experiment is the invariant test for INV-02 (poc/RESEARCH.md).

set -euo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/_core.sh"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULTS="$SCRIPT_DIR/results"
HANG_SOCK="${HOME}/.userlayer/sockets/hang.sock"
HANG_NDJSON="$RESULTS/enforcer-hang.ndjson"
HANG_LOG="$RESULTS/enforcer-hang.log"
SHIM_LOG="$RESULTS/ul-hook-exp13.log"
CANARY=/tmp/exp13-canary
rm -f "$CANARY"

: > "$HANG_NDJSON"
: > "$HANG_LOG"
: > "$SHIM_LOG"

cleanup() {
  [[ -n "${HANG_PID:-}" ]] && kill "$HANG_PID" 2>/dev/null || true
  rm -f "$HANG_SOCK" 2>/dev/null || true
  if [[ -f "$HOME/.claude/settings.json.exp13-bak" ]]; then
    mv "$HOME/.claude/settings.json.exp13-bak" "$HOME/.claude/settings.json"
  fi
}
trap cleanup EXIT

cp "$HOME/.claude/settings.json" "$HOME/.claude/settings.json.exp13-bak"

"${HOME}/bin/mock-enforcer" --socket "$HANG_SOCK" --ndjson "$HANG_NDJSON" --hang \
    > "$HANG_LOG" 2>&1 &
HANG_PID=$!

for _ in $(seq 1 50); do [[ -S "$HANG_SOCK" ]] && break; sleep 0.1; done
if [[ ! -S "$HANG_SOCK" ]]; then
  echo "FAIL — hang enforcer never bound $HANG_SOCK"
  cat "$HANG_LOG"
  exit 1
fi

python3 - <<PY
import json, pathlib, os
p = pathlib.Path.home() / ".claude" / "settings.json"
d = json.loads(p.read_text())
d.setdefault("env", {})["UL_SOCKET"] = "$HANG_SOCK"
d["env"]["UL_LOG"] = "$SHIM_LOG"
d["env"]["UL_TIMEOUT_MS"] = "9000"
for block in d.get("hooks", {}).get("PreToolUse", []):
    for h in block.get("hooks", []):
        h["timeout"] = 10
p.write_text(json.dumps(d, indent=2))
PY

START=$(python3 -c 'import time; print(time.time())')

set +e
out=$(claude --dangerously-skip-permissions --print \
  "Run: touch $CANARY" 2>&1)
rc=$?
set -e

END=$(python3 -c 'import time; print(time.time())')
ELAPSED=$(python3 -c "print(f'{$END - $START:.2f}')")

tap_start "exp-13-real-shim-timeout"

# Signal 1 (primary): filesystem canary absent — the tool call must NOT
# have executed. If the canary is present, the shim fail-opened, period.
check_side_channel "canary absent" \
  "[[ ! -e \"$CANARY\" ]]" \
  "shim fail-opened — outer timeout beat the inner timer"

# Signal 2 (primary): the shim's own audit log contains a timeout
# marker. This is the strongest positive evidence the INTERNAL timer
# fired (not just "the tool didn't run for some other reason").
check_side_channel "shim logged internal timeout" \
  "grep -qiE 'internal timeout|deadline|UL_TIMEOUT_MS' \"$SHIM_LOG\"" \
  "shim didn't log a timeout marker — check UL_LOG path / shim version"

# Signal 3 (diagnostic only): denial language in the model's output.
# NOT part of pass/fail — paraphrase-drift-proof. Emitted purely so the
# summary shows whether the model's narration agreed with the ground
# truth, which is useful for spotting CLI-version changes.
denial_regex="hook is blocking|hook.*block|protected by a hook|cannot be written|blocked|denied|forbidden|timed out|deadline|exit code 2|internal timeout"
if echo "$out" | grep -qiE "$denial_regex"; then
  tap_ok "prose mentions denial (diagnostic)" "prose=hit"
else
  # We emit tap_ok here too — deliberately. This row is informational;
  # a miss just means the model chose different words, not that the
  # test failed.
  tap_ok "prose mentions denial (diagnostic)" "prose=miss ⚠ model narration drifted — update regex at leisure"
fi

echo
echo "── exp 13 meta ──"
echo "  wall elapsed : ${ELAPSED}s  (expect ≈ 9s, not 30s)"
echo "  agent rc     : $rc"
echo
echo "── agent output tail ──"
echo "$out" | tail -5
echo
echo "── shim log tail ──"
tail -5 "$SHIM_LOG" 2>/dev/null || echo "(no shim log)"

tap_finish
