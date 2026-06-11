#!/usr/bin/env bash
# rerun-exp.sh — standalone rerun of ONE experiment by number.
#
# Usage:
#   bash rerun-exp.sh 02         # reruns experiment-02-*.sh
#   bash rerun-exp.sh 13         # reruns experiment-13-*.sh
#
# Why a generic runner?
#   • exp-16 has its own rerun-exp16.sh because it's a 40-min fuzzer with
#     special expectations. For everything else, we need a fast iterate-on-
#     one-experiment loop without paying the cost of all 16.
#   • Round-4 patch cycle exposed false negatives in exp-02 (regex too
#     narrow) and a latent CLI-version regression in exp-03. Iterating on
#     fixes for those was painful when each round meant a 5-min full
#     harness pass.
#
# Preconditions match rerun-exp16.sh — see that file for details.
#
# Exit code: passes through the exit code of the chosen experiment.

set -euo pipefail
cd "$(dirname "$0")"

if [[ $# -ne 1 || ! "$1" =~ ^[0-9]{2}$ ]]; then
  echo "usage: $0 <NN>      # e.g. 02, 03, 13, 16"
  echo "available:"
  ls experiment-*.sh 2>/dev/null | sed 's/^/  /'
  exit 2
fi
N="$1"

# Resolve experiment script (supports "experiment-02-*.sh" naming).
EXP=$(ls experiment-${N}-*.sh 2>/dev/null | head -n1)
if [[ -z "$EXP" || ! -f "$EXP" ]]; then
  echo "✗ no experiment script found for number $N"
  exit 2
fi
NAME=$(basename "$EXP" .sh)

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

GRN=$'\e[32m'; RED=$'\e[31m'; YLW=$'\e[33m'; DIM=$'\e[2m'; RST=$'\e[0m'

# ── 1. kill stray enforcer(s) ───────────────────────────────────────────
if pgrep -f 'mock-enforcer' >/dev/null 2>&1; then
  echo "⚠ existing mock-enforcer detected; terminating"
  pkill -f 'mock-enforcer' || true
  for _ in $(seq 1 20); do
    pgrep -f 'mock-enforcer' >/dev/null 2>&1 || break
    sleep 0.1
  done
fi
rm -f "$SOCK"

# ── 2. fresh NDJSON sink ────────────────────────────────────────────────
NDJSON="$RESULTS/enforcer.ndjson"
: > "$NDJSON"
export UL_NDJSON="$NDJSON"

# ── 3. start enforcer ───────────────────────────────────────────────────
echo "▶ starting mock-enforcer on $SOCK (NDJSON → $NDJSON)"
"$ENFORCER" --socket "$SOCK" --ndjson "$NDJSON" >"$RESULTS/enforcer.log" 2>&1 &
ENF_PID=$!
trap 'kill $ENF_PID 2>/dev/null || true; rm -f "$SOCK" 2>/dev/null || true' EXIT

for _ in $(seq 1 50); do [[ -S "$SOCK" ]] && break; sleep 0.1; done
[[ -S "$SOCK" ]] || { echo "✗ enforcer never bound $SOCK"; cat "$RESULTS/enforcer.log"; exit 1; }

# ── 4. capture CLI version (Round-4 diagnostic) ─────────────────────────
# Without this, a silent CLI bump can change hook semantics (e.g. timeout
# fail-open vs fail-closed in exp-03) and leave us guessing why a green
# test went red. Always print and append to summary so reruns are
# self-describing.
CLAUDE_VER="$(claude --version 2>/dev/null || echo 'unknown')"
echo "▶ claude --version: $CLAUDE_VER"

# ── 5. re-apply settings.json (belt-and-suspenders) ─────────────────────
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

# ── 6. run the chosen experiment ────────────────────────────────────────
[[ -x "$EXP" ]] || chmod +x "$EXP"

printf '\n── %s (standalone rerun, claude=%s) ─────────\n' "$NAME" "$CLAUDE_VER"
set +e
bash "$EXP" 2>&1 | tee "$RESULTS/${NAME}.log"
rc=${PIPESTATUS[0]}
set -e

# ── 7. report ───────────────────────────────────────────────────────────
if   [[ $rc -eq 0  ]]; then STATUS="${GRN}✅${RST}"
elif [[ $rc -eq 77 ]]; then STATUS="${YLW}⊙ SKIP${RST}"
else                        STATUS="${RED}❌${RST}"
fi

NDJSON_ROWS=$(wc -l < "$NDJSON" 2>/dev/null | tr -d ' ')
NDJSON_ROWS=${NDJSON_ROWS:-0}

echo
echo "════════ standalone rerun summary ════════"
date -u +"generated: %Y-%m-%dT%H:%M:%SZ"
printf '  claude:        %s\n' "$CLAUDE_VER"
printf '  %s  %-45s rc=%d\n' "$STATUS" "$NAME" "$rc"
printf '  NDJSON rows:   %s    (%s)\n' "$NDJSON_ROWS" "$NDJSON"
printf '  enforcer.log tail (last 10 lines):\n'
tail -n 10 "$RESULTS/enforcer.log" 2>/dev/null | sed 's/^/    /' || echo "    (no log)"

exit "$rc"
