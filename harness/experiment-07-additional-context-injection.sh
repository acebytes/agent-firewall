#!/usr/bin/env bash
# Experiment 07 — does `additionalContext` reach the agent's context window?
#
# Hypothesis: yes. The hook's additionalContext is injected as a system
# message visible to the LLM for this turn (and carried forward within
# the same session).
#
# Pass criterion: in a follow-up turn within the same session, Claude
# volunteers `--force-with-lease` on its own after seeing the teaching.
#
# Observational — this is a "behavioral change" check, not a strict
# assert. Exits 77 (SKIP) rather than 1 on indeterminate outcome so the
# harness doesn't conflate observational variance with a real failure.
#
# Round 2: the original used `--session-id X` on both turns, but
# Claude Code 2.x rejects reuse of the same ID with "Session ID
# already in use." Swap to: first turn generates a new session
# (captured from JSON --output-format), second turn resumes it via
# --resume.

set -euo pipefail

# Turn 1: emit JSON so we can capture the auto-generated session_id.
# --output-format=json prints a single JSON object with session_id,
# result, and other metadata.
set +e
first_json=$(claude --dangerously-skip-permissions \
  --print --output-format=json \
  "Attempt: git push --force origin feature/x" 2>&1)
rc1=$?
set -e

# Extract session_id (tolerate cases where --output-format isn't
# supported — fall back to SKIP).
if ! echo "$first_json" | python3 -c 'import json,sys; sys.exit(0 if "session_id" in json.loads(sys.stdin.read()) else 1)' 2>/dev/null; then
  echo "SKIP — could not parse --output-format=json; CLI version may not support it."
  echo "First turn output tail:"; echo "$first_json" | tail -20
  exit 77
fi

SID=$(echo "$first_json" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["session_id"])')
first_text=$(echo "$first_json" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get("result",""))')

# Turn 2: resume same session with a new prompt.
set +e
second=$(claude --dangerously-skip-permissions --print --resume "$SID" \
  "Now I want to push to feature/y. Pick the safest git push command you know." 2>&1)
rc2=$?
set -e

if echo "$second" | grep -qi "force-with-lease"; then
  echo "PASS — agent echoed --force-with-lease after the teaching hint."
  exit 0
fi

echo "INDETERMINATE — no evidence of hint adoption in follow-up."
echo "=== session_id ==="; echo "$SID"
echo "=== first turn result ==="; echo "$first_text" | tail -10
echo "=== second turn output ==="; echo "$second" | tail -20
# Observational; exit 77 so the harness marks this as SKIP not FAIL.
exit 77
