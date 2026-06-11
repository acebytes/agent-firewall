#!/usr/bin/env bash
# Experiment 09 — does `settings.json.env` successfully set env vars for
# the hook subprocess?
#
# Hypothesis: yes — Claude Code forwards `env` to hook subprocesses.
# Verifying this lets us use UL_ACTIVE_CAP to signal which cap is active
# without the enforcer having to guess.
#
# Pass criterion: a UL_ACTIVE_CAP sentinel placed in settings.env appears
# in the NDJSON audit stream's cap field (the shim copies UL_ACTIVE_CAP
# → capHint → enforcer's cap field on each request).
#
# ROUND-5 REFACTOR
# ────────────────
# Previous version grep'd the human-readable enforcer.log for
# "cap=.*sentinel-09". That was already a side-channel (not model prose),
# so exp-09 was never strictly paraphrase-sensitive — but the log format
# is less stable than the NDJSON schema. Ported to ndjson_assert_any
# with time-windowing so cross-experiment run noise can't false-positive
# on a leftover sentinel from a previous experiment.

set -euo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/_core.sh"

SENTINEL="firewall.dev-assistant@sentinel-09"

python3 - <<PY
import json, os, pathlib
p = pathlib.Path.home() / ".claude" / "settings.json"
d = json.loads(p.read_text())
d.setdefault("env", {})["UL_ACTIVE_CAP"] = "$SENTINEL"
p.write_text(json.dumps(d, indent=2))
PY

tap_start "exp-09-hook-env-injection"

# Capture a narrow time window so we only see events this experiment
# triggered, not any accumulated sentinel hits from earlier runs.
since="$(since_ts_utc)"

# Fire one allow-path Bash call so the enforcer records something.
_=$(claude --dangerously-skip-permissions --print "Run: pwd" 2>&1) || true

# Primary ground-truth check: the NDJSON audit stream should contain at
# least one event (any decision) whose `cap` field contains the sentinel
# string — proving:
#   1. Claude Code forwarded settings.env.UL_ACTIVE_CAP to the hook.
#   2. The shim read it, set capHint on the HookRequest, and dialed
#      the enforcer.
#   3. The enforcer logged the capHint into the cap field of its event.
if ndjson_assert_any "any" "cap" "sentinel-09" "$since"; then
  tap_ok "sentinel in ndjson cap field" "enforcer=hit  needle=sentinel-09  since=$since"
else
  # Diagnostic: print what WAS in the stream, so a sandbox misconfig is
  # distinguishable from a real env-propagation failure.
  tap_not_ok "sentinel in ndjson cap field" \
    "enforcer=miss  (no cap-field match since $since)"
  echo "── diagnostic: recent enforcer events ──" >&2
  tail -10 "$(ndjson_path)" 2>/dev/null >&2 || true
fi

tap_finish
