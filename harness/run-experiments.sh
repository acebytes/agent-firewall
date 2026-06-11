#!/usr/bin/env bash
# run-experiments.sh — in-container orchestrator for all 12 experiments.
#
# Called by the Docker CMD. Assumes:
#   • $HOME/bin/ul-hook and $HOME/bin/mock-enforcer already exist (baked in image)
#   • ANTHROPIC_API_KEY is exported (via --env-file on host)
#
# Steps:
#   1. Launch mock-enforcer in the background on a fresh Unix socket
#   2. Write ~/.claude/settings.json so Claude Code invokes the shim
#   3. Run experiment-*.sh in sequence, capturing each to results/<n>.log
#   4. Write a summary.txt with pass/fail/rows and overall exit code
#
# Exits 0 iff every experiment returns 0. Script safe to re-run
# (enforcer is killed, socket and settings.json are recreated).

set -euo pipefail

cd "$(dirname "$0")"

# ── config ──────────────────────────────────────────────────────────────
RESULTS="${PWD}/results"
mkdir -p "$RESULTS"

BIN_DIR="${HOME}/bin"
UL_HOOK="${BIN_DIR}/ul-hook"
ENFORCER="${BIN_DIR}/mock-enforcer"

SOCK="${UL_SOCKET:-${HOME}/.userlayer/sockets/enforcer.sock}"
mkdir -p "$(dirname "$SOCK")"
chmod 700 "$(dirname "$SOCK")"

[[ -x "$UL_HOOK"   ]] || { echo "✗ ul-hook binary missing at $UL_HOOK"; exit 1; }
[[ -x "$ENFORCER"  ]] || { echo "✗ mock-enforcer binary missing at $ENFORCER"; exit 1; }
[[ -n "${ANTHROPIC_API_KEY:-}" ]] || {
  echo "✗ ANTHROPIC_API_KEY not set; pass it via docker --env-file .env"; exit 1; }

# ── colours ─────────────────────────────────────────────────────────────
GRN=$'\e[32m'; RED=$'\e[31m'; YLW=$'\e[33m'; DIM=$'\e[2m'; RST=$'\e[0m'

# ── start enforcer ──────────────────────────────────────────────────────
# Round 3: NDJSON audit sink goes next to the socket; experiments and CI
# can diff results/enforcer.ndjson across rounds for machine-readable
# regression signals (decision distribution, p99 latency, rule frequency).
NDJSON="$RESULTS/enforcer.ndjson"
: > "$NDJSON"   # truncate from previous run

# Export UL_NDJSON so any enforcer restart by any experiment (exp-06's
# EXIT trap, future hotswap experiments, etc.) inherits the correct
# bind-mounted audit path. Without this, restarted enforcers fall back
# to ~/.userlayer/sockets/enforcer.ndjson which is NOT bind-mounted to
# the host and is discarded when the container exits.
export UL_NDJSON="$NDJSON"

echo "▶ starting mock-enforcer on $SOCK (NDJSON → $NDJSON)"
"$ENFORCER" --socket "$SOCK" --ndjson "$NDJSON" >"$RESULTS/enforcer.log" 2>&1 &
ENF_PID=$!
trap 'kill $ENF_PID 2>/dev/null || true; rm -f "$SOCK" 2>/dev/null || true' EXIT

# Wait up to 5s for the socket to bind
for _ in $(seq 1 50); do [[ -S "$SOCK" ]] && break; sleep 0.1; done
[[ -S "$SOCK" ]] || { echo "✗ enforcer never bound $SOCK"; cat "$RESULTS/enforcer.log"; exit 1; }

# ── wire Claude Code ────────────────────────────────────────────────────
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

# ── run each experiment ─────────────────────────────────────────────────
declare -a NAMES
declare -A RESULT_STATUS RESULT_CODE
# Round-5 addition: if an experiment emits TAP sub-rows (ok/not ok N - name),
# capture them for inclusion in summary.txt as indented child rows. The
# per-experiment log is still authoritative; the aggregator just projects
# the TAP block up into the summary view so multi-case experiments show
# their breakdown in one glance.
declare -A RESULT_TAP

for exp in experiment-*.sh; do
  [[ -x "$exp" ]] || chmod +x "$exp"
  name=$(basename "$exp" .sh)
  NAMES+=("$name")
  printf '\n── %s ─────────────────────────────\n' "$name"
  set +e
  bash "$exp" >"$RESULTS/$name.log" 2>&1
  rc=$?
  set -e
  RESULT_CODE[$name]=$rc
  if [[ $rc -eq 0 ]]; then
    RESULT_STATUS[$name]="${GRN}✅${RST}"
  elif [[ $rc -eq 77 ]]; then
    RESULT_STATUS[$name]="${YLW}⊙ SKIP${RST}"
  else
    RESULT_STATUS[$name]="${RED}❌${RST} ($rc)"
  fi
  printf '  %s %s → %s\n' "${RESULT_STATUS[$name]}" "$name" "${DIM}results/$name.log${RST}"

  # Capture any TAP sub-rows this experiment emitted. Matches lines of
  # the form "ok N - label  # tags" and "not ok N - label  # tags",
  # between "# TAP-fixture:" and "# TAP-end N" sentinels.
  tap_block=$(awk '
    /^# TAP-fixture:/ {inblk=1; next}
    /^# TAP-end /     {inblk=0; next}
    inblk && /^(ok|not ok) [0-9]+ - / {print}
  ' "$RESULTS/$name.log" 2>/dev/null || true)
  [[ -n "$tap_block" ]] && RESULT_TAP[$name]="$tap_block"
done

# ── summary ─────────────────────────────────────────────────────────────
# Round-4 additions:
#   • capture `claude --version` so CLI bumps (e.g. hook-timeout fail-open
#     semantics) can't flip a test silently — if exp-03/13 behavior shifts,
#     this line tells you which CLI build to compare against.
#   • NDJSON line count is a compact observability canary at the summary
#     level too (exp-16's I0 checks it, but showing it in summary.txt means
#     a one-glance regression signal even if the fuzzer isn't enabled).
CLAUDE_VER="$(claude --version 2>/dev/null || echo 'unknown')"
NDJSON_ROWS=$(wc -l < "$NDJSON" 2>/dev/null | tr -d ' ')
NDJSON_ROWS=${NDJSON_ROWS:-0}

{
  echo "════════ SUMMARY ════════"
  date -u +"generated: %Y-%m-%dT%H:%M:%SZ"
  echo "claude CLI:  $CLAUDE_VER"
  echo "NDJSON rows: $NDJSON_ROWS    ($NDJSON)"
  echo
  for n in "${NAMES[@]}"; do
    printf '  %-55s rc=%d\n' "$n" "${RESULT_CODE[$n]}"
    # Round-5: render TAP sub-rows as indented children when present.
    # Each line is a labeled sub-check with both signals (enforcer +
    # prose). Keeps the parent row a single rc, but the breakdown is
    # one glance away rather than buried in the .log file.
    if [[ -n "${RESULT_TAP[$n]:-}" ]]; then
      while IFS= read -r line; do
        printf '      %s\n' "$line"
      done <<< "${RESULT_TAP[$n]}"
    fi
  done
} | tee "$RESULTS/summary.txt"

echo
echo "logs in ./results/"
echo

# Overall exit nonzero if any non-skip experiment failed.
fail=0
for n in "${NAMES[@]}"; do
  rc=${RESULT_CODE[$n]}
  [[ $rc -eq 0 || $rc -eq 77 ]] || fail=1
done
exit $fail
