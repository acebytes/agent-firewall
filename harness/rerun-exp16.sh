#!/usr/bin/env bash
# rerun-exp16.sh — standalone rerun of JUST experiment-16-invariant-fuzz.
#
# Context: exp 16 is the 500-trial statistical fuzzer (~40–50 min). Re-running
# the full 16-experiment harness to iterate on it wastes ~5 min of fixed-cost
# experiments 01–15 every cycle. This script brings up a fresh enforcer,
# re-applies ~/.claude/settings.json, and invokes experiment-16 only.
#
# Intended invocation paths:
#   a) From the host:       ./run.sh exp16
#   b) Inside the container: ./run.sh shell   →   bash harness/rerun-exp16.sh
#
# Preconditions:
#   • $HOME/bin/mock-enforcer and $HOME/bin/ul-hook already built into image
#   • ANTHROPIC_API_KEY exported (harness container receives via --env-file)
#   • Round-3 enforcer patch in effect (self-healing NDJSON sink — see
#     mock-enforcer/main.go auditSink). Rebuild with `./run.sh rebuild`
#     before using this script if the image predates the patch.
#
# Exit code: passes through the exit code of experiment-16.

set -euo pipefail
cd "$(dirname "$0")"

RESULTS="${PWD}/results"
mkdir -p "$RESULTS"

BIN_DIR="${HOME}/bin"
UL_HOOK="${BIN_DIR}/ul-hook"
ENFORCER="${BIN_DIR}/mock-enforcer"

SOCK="${UL_SOCKET:-${HOME}/.userlayer/sockets/enforcer.sock}"
mkdir -p "$(dirname "$SOCK")"
chmod 700 "$(dirname "$SOCK")"

[[ -x "$UL_HOOK"  ]] || { echo "✗ ul-hook binary missing at $UL_HOOK"; exit 1; }
[[ -x "$ENFORCER" ]] || { echo "✗ mock-enforcer binary missing at $ENFORCER"; exit 1; }
[[ -n "${ANTHROPIC_API_KEY:-}" ]] || {
  echo "✗ ANTHROPIC_API_KEY not set; pass it via docker --env-file .env"; exit 1; }

# ── colours ─────────────────────────────────────────────────────────────
GRN=$'\e[32m'; RED=$'\e[31m'; YLW=$'\e[33m'; DIM=$'\e[2m'; RST=$'\e[0m'

# ── 1. kill stray enforcer(s) ───────────────────────────────────────────
if pgrep -f 'mock-enforcer' >/dev/null 2>&1; then
  echo "⚠ existing mock-enforcer detected; terminating"
  pkill -f 'mock-enforcer' || true
  # wait for them to release the socket
  for _ in $(seq 1 20); do
    pgrep -f 'mock-enforcer' >/dev/null 2>&1 || break
    sleep 0.1
  done
fi
rm -f "$SOCK"

# ── 2. fresh NDJSON sink ────────────────────────────────────────────────
NDJSON="$RESULTS/enforcer.ndjson"
: > "$NDJSON"

# Inherit env var so anything that transitively restarts the enforcer
# (none today, but cheap insurance) writes to the correct path.
export UL_NDJSON="$NDJSON"

# ── 3. start enforcer ───────────────────────────────────────────────────
echo "▶ starting mock-enforcer on $SOCK (NDJSON → $NDJSON)"
"$ENFORCER" --socket "$SOCK" --ndjson "$NDJSON" >"$RESULTS/enforcer.log" 2>&1 &
ENF_PID=$!
trap 'kill $ENF_PID 2>/dev/null || true; rm -f "$SOCK" 2>/dev/null || true' EXIT

for _ in $(seq 1 50); do [[ -S "$SOCK" ]] && break; sleep 0.1; done
[[ -S "$SOCK" ]] || { echo "✗ enforcer never bound $SOCK"; cat "$RESULTS/enforcer.log"; exit 1; }

# ── 4. re-apply settings.json (belt-and-suspenders) ─────────────────────
# If the previous harness run was killed mid-experiment, exp-13's EXIT trap
# may not have restored settings.json. Rewrite it unconditionally.
mkdir -p "$HOME/.claude"
cat > "$HOME/.claude/settings.json" <<EOF
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash|Write|Edit|Read|Glob|Grep|WebFetch|WebSearch|Agent|mcp__.*",
        "hooks": [
          { "type": "command",
            "command": "$UL_HOOK",
            "timeout": 10 }
        ]
      }
    ]
  },
  "env": {
    "UL_SOCKET": "$SOCK",
    "UL_TIMEOUT_MS": "9000",
    "UL_ADAPTER": "claude-code"
  }
}
EOF

# ── 5. run only experiment-16 ───────────────────────────────────────────
EXP="experiment-16-invariant-fuzz.sh"
[[ -x "$EXP" ]] || chmod +x "$EXP"

printf '\n── %s (standalone rerun) ─────────\n' "$EXP"
set +e
bash "$EXP" 2>&1 | tee "$RESULTS/experiment-16-invariant-fuzz.log"
rc=${PIPESTATUS[0]}
set -e

# ── 6. report ───────────────────────────────────────────────────────────
if [[ $rc -eq 0 ]]; then
  STATUS="${GRN}✅${RST}"
elif [[ $rc -eq 77 ]]; then
  STATUS="${YLW}⊙ SKIP${RST}"
else
  STATUS="${RED}❌${RST}"
fi

NDJSON_ROWS=$(wc -l < "$NDJSON" 2>/dev/null | tr -d ' ')
NDJSON_ROWS=${NDJSON_ROWS:-0}

echo
echo "════════ standalone rerun summary ════════"
date -u +"generated: %Y-%m-%dT%H:%M:%SZ"
printf '  %s  experiment-16-invariant-fuzz   rc=%d\n' "$STATUS" "$rc"
printf '  NDJSON rows:   %s    (%s)\n' "$NDJSON_ROWS" "$NDJSON"
printf '  enforcer.log tail (last 10 lines):\n'
tail -n 10 "$RESULTS/enforcer.log" 2>/dev/null | sed 's/^/    /' || echo "    (no log)"

exit "$rc"
