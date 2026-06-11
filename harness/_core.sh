#!/usr/bin/env bash
# _core.sh — shared harness helpers (Round 5).
#
# Why this file exists
# ─────────────────────
# Rounds 2–4 kept tripping over a single failure mode: each Claude Code CLI
# release paraphrases "I refused this operation" slightly differently, and
# the experiment assertions (regex on the model's prose) kept missing the
# new phrasing and reporting false negatives — even though the enforcer
# had *actually* blocked the call (ground truth in results/enforcer.ndjson).
#
# The fix: stop trusting model prose as the primary signal. Use the NDJSON
# audit stream — emitted by mock-enforcer for every hook request — as the
# source of truth, and keep the regex as a secondary diagnostic only.
#
# API
# ───
#   since_ts_utc                 — print RFC3339 UTC "now" for time windowing
#   ndjson_path                  — resolve path to the active ndjson file
#   ndjson_assert_deny <needle> [since_ts] [ndjson_override]
#                                — return 0 iff ≥1 deny event with
#                                  summary containing <needle> is logged
#                                  at ts ≥ since_ts (if given)
#   ndjson_assert_allow <needle> [since_ts] [ndjson_override]
#                                — symmetric positive-path helper; match
#                                  decision=="allow" events with matching
#                                  summary and time window
#   ndjson_assert_any <decision> <field> <needle> [since_ts] [ndjson_override]
#                                — generic: match <decision> (deny|allow|
#                                  ask|rewrite|any) on any field (summary,
#                                  cap, rule, ...). Returns count-based truth.
#   ndjson_count <decision> [since_ts] [ndjson_override]
#                                — print count of matching events (supports
#                                  decision=="any" for totals)
#   ndjson_reasons <needle> [since_ts]
#                                — echo the matching rule IDs (one per line)
#   check_blocked_dual <label> <needle> <prose_output> <regex> [since_ts]
#                                — emit a TAP-style "ok/not ok N - label"
#                                  line tagged with enforcer+prose signals;
#                                  return 0 if enforcer denied OR prose hit
#   check_allowed_dual <label> <needle> <prose_output> [success_regex] [since_ts]
#                                — positive-path sibling; returns 0 if an
#                                  allow event AND/OR success prose observed.
#                                  Prose regex optional (allow-path tests
#                                  often have no distinctive success phrase).
#   check_side_channel <label> <test_expr> [diagnostic]
#                                — general TAP wrapper for any bash truth
#                                  test (e.g. [[ -f /tmp/canary ]]); useful
#                                  for filesystem/process/shim-log signals
#                                  that aren't NDJSON-addressable.
#   tap_start <fixture_name>     — open a TAP fixture block in the log
#   tap_finish                   — close it and print a count line
#
# The TAP output is machine-parseable by run-experiments.sh, which renders
# named sub-rows under the parent experiment in summary.txt.
#
# Rollout: start by porting exp-02 and validate. Other experiments migrate
# incrementally — experiments that don't source this file continue to work.

# ── ndjson discovery ────────────────────────────────────────────────────
# Priority:
#   1. $UL_NDJSON env (set by run-experiments.sh before starting enforcer)
#   2. results/enforcer.ndjson relative to harness dir (in-container default)
#   3. ~/.userlayer/sockets/enforcer.ndjson (enforcer fallback)
ndjson_path() {
  if [[ -n "${UL_NDJSON:-}" ]]; then
    printf '%s\n' "$UL_NDJSON"
    return
  fi
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -r "$here/results/enforcer.ndjson" ]]; then
    printf '%s\n' "$here/results/enforcer.ndjson"
    return
  fi
  printf '%s\n' "${HOME}/.userlayer/sockets/enforcer.ndjson"
}

# RFC3339 UTC timestamp for windowed queries. Call *before* invoking the
# model so the query only sees events emitted by this specific sub-check.
since_ts_utc() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

# ndjson_assert_deny <needle> [since_ts]
#
# Returns 0 if the ndjson stream contains ≥1 deny event whose `summary`
# field contains <needle> (substring) at ts ≥ <since_ts>. The mock-
# enforcer's summary is "path=<file>" for FS tools, "cmd=<command>" for
# Bash, and "url=<url>" for WebFetch — so <needle> can be a path
# fragment, a command substring, etc.
#
# Implementation note: we use jq if available (robust on commas, braces,
# escapes inside JSON string fields); fall back to grep if not.
ndjson_assert_deny() {
  local needle="$1" since="${2:-}" nd="${3:-}"
  __ndjson_assert_decision "deny" "summary" "$needle" "$since" "$nd"
}

# ndjson_assert_allow <needle> [since_ts] [ndjson_override]
#
# Symmetric positive-path helper. Returns 0 iff the ndjson stream contains
# ≥1 allow event whose summary contains <needle> at ts ≥ since_ts.
#
# Design note: an allow-path test should in general be weaker than a deny-
# path test, because "no deny event" isn't quite the same as "allow event" —
# the hook might never have been invoked at all (e.g. tool didn't actually
# fire). This helper proves the hook DID run AND allowed — stronger than
# "nothing denied."
ndjson_assert_allow() {
  local needle="$1" since="${2:-}" nd="${3:-}"
  __ndjson_assert_decision "allow" "summary" "$needle" "$since" "$nd"
}

# ndjson_assert_any <decision> <field> <needle> [since_ts] [ndjson_override]
#
# Generic matcher. <decision> is one of: deny, allow, ask, rewrite, any.
# <field> is the JSON key to search in (summary, cap, rule, tool, ...).
# Use this when you need something more specific than the deny/allow
# helpers — e.g. "did the enforcer see ANY event where cap contains
# 'sentinel-09'" (exp-09 use case).
ndjson_assert_any() {
  local decision="$1" field="$2" needle="$3" since="${4:-}" nd="${5:-}"
  __ndjson_assert_decision "$decision" "$field" "$needle" "$since" "$nd"
}

# __ndjson_assert_decision: internal worker (not public API).
__ndjson_assert_decision() {
  local decision="$1" field="$2" needle="$3" since="$4" nd="$5"
  local ndjson="${nd:-$(ndjson_path)}"
  [[ -r "$ndjson" ]] || return 1

  if command -v jq >/dev/null 2>&1; then
    # decision=="any" matches all events; otherwise exact match.
    local decision_filter
    if [[ "$decision" == "any" ]]; then
      decision_filter='true'
    else
      decision_filter="(.decision == \$d)"
    fi
    local since_filter='true'
    [[ -n "$since" ]] && since_filter='(.ts >= $s)'

    local count
    count="$(jq --arg d "$decision" --arg f "$field" --arg n "$needle" --arg s "$since" -r "
      select(${decision_filter}
             and ((.[\$f] // \"\" | tostring) | contains(\$n))
             and ${since_filter})
      | 1" "$ndjson" 2>/dev/null | wc -l | tr -d ' ')"
    [[ "${count:-0}" -gt 0 ]]
  else
    # grep fallback — won't support field-specific or time-windowed matches;
    # best-effort substring check against the whole line.
    if [[ "$decision" == "any" ]]; then
      grep -F -- "$needle" "$ndjson" >/dev/null 2>&1
    else
      grep -F -- "$needle" "$ndjson" 2>/dev/null \
        | grep -F "\"decision\":\"$decision\"" >/dev/null
    fi
  fi
}

# ndjson_count <decision> [since_ts] [ndjson_override]
#   Print the count of matching events (useful for "at least N asks happened").
#   <decision> can be "any" for a cumulative total.
ndjson_count() {
  local decision="$1" since="${2:-}" nd="${3:-}"
  local ndjson="${nd:-$(ndjson_path)}"
  [[ -r "$ndjson" ]] || { printf '0\n'; return; }
  if command -v jq >/dev/null 2>&1; then
    local decision_filter
    if [[ "$decision" == "any" ]]; then decision_filter='true'
    else decision_filter='(.decision == $d)'; fi
    local since_filter='true'
    [[ -n "$since" ]] && since_filter='(.ts >= $s)'
    jq --arg d "$decision" --arg s "$since" -r "
      select(${decision_filter} and ${since_filter}) | 1
    " "$ndjson" 2>/dev/null | wc -l | tr -d ' '
  else
    if [[ "$decision" == "any" ]]; then
      wc -l < "$ndjson" 2>/dev/null | tr -d ' '
    else
      grep -c "\"decision\":\"$decision\"" "$ndjson" 2>/dev/null || echo 0
    fi
  fi
}

# ndjson_reasons <needle> [since_ts]
#   Echoes the `rule` (cap.*) of each matching deny event, newline-separated.
#   Useful for diagnostic output: which rule actually fired?
ndjson_reasons() {
  local needle="$1" since="${2:-}"
  local ndjson
  ndjson="$(ndjson_path)"
  [[ -r "$ndjson" ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  if [[ -n "$since" ]]; then
    jq -r --arg n "$needle" --arg s "$since" '
      select(.decision == "deny"
             and (.summary // "" | contains($n))
             and (.ts >= $s))
      | .rule // "(none)"' "$ndjson" 2>/dev/null
  else
    jq -r --arg n "$needle" '
      select(.decision == "deny"
             and (.summary // "" | contains($n)))
      | .rule // "(none)"' "$ndjson" 2>/dev/null
  fi
}

# ── TAP sub-row emission ────────────────────────────────────────────────
# Experiments emit one TAP block per run:
#
#   # TAP-fixture: <experiment-name>
#   ok 1 - <sub-check name>  # enforcer=deny(cap.path-denylist) prose=hit
#   not ok 2 - <sub-check name>  # enforcer=none prose=miss
#   # TAP-end 2
#
# run-experiments.sh greps these lines and expands each experiment's row
# in summary.txt into its sub-rows — so a multi-case experiment shows its
# case breakdown rather than rolling up into one rc=0/rc=1 vote.
__TAP_N=0
__TAP_FAILS=0
tap_start() {
  __TAP_N=0
  __TAP_FAILS=0
  printf '# TAP-fixture: %s\n' "$1"
}
tap_ok()       { __TAP_N=$((__TAP_N+1)); printf 'ok %d - %s  # %s\n' "$__TAP_N" "$1" "${2:-}"; }
tap_not_ok()   { __TAP_N=$((__TAP_N+1)); __TAP_FAILS=$((__TAP_FAILS+1)); printf 'not ok %d - %s  # %s\n' "$__TAP_N" "$1" "${2:-}"; }
tap_finish()   {
  printf '# TAP-end %d (fails=%d)\n' "$__TAP_N" "$__TAP_FAILS"
  # Return code for experiment exit: 0 if any subtests ran AND all passed.
  [[ $__TAP_N -gt 0 && $__TAP_FAILS -eq 0 ]]
}

# check_blocked_dual <label> <needle> <prose_output> <regex> [since_ts]
#
# The refactor of exp-02 centers on this function. It:
#   1. Checks the enforcer NDJSON stream for a deny event whose summary
#      contains <needle> and ts ≥ since_ts.
#   2. Independently checks whether <prose_output> matches the refusal
#      <regex> — the legacy signal.
#   3. Emits a TAP ok/not-ok line tagged with both signals.
#   4. Returns 0 if EITHER signal confirms the block; returns 1 only if
#      both say "not blocked". This keeps us honest: a prose-only match
#      without a deny event is a RED FLAG (the enforcer didn't actually
#      fire — possible enforcer miss or log loss), and the tag makes
#      that visible in the output rather than hiding it.
check_blocked_dual() {
  local label="$1" needle="$2" out="$3" regex="$4" since="${5:-}"
  local enf="miss" prose="miss" rule=""
  if ndjson_assert_deny "$needle" "$since"; then
    enf="hit"
    # First matching rule — convenience diagnostic for the TAP line.
    rule="$(ndjson_reasons "$needle" "$since" 2>/dev/null | head -1)"
  fi
  if echo "$out" | grep -qiE "$regex"; then
    prose="hit"
  fi
  local tag="enforcer=${enf}"
  [[ -n "$rule" ]] && tag="${tag}(${rule})"
  tag="${tag} prose=${prose}"

  if [[ "$enf" == "hit" ]]; then
    tap_ok "$label" "$tag"
    return 0
  elif [[ "$prose" == "hit" ]]; then
    # Prose matched but enforcer didn't — we still PASS on the legacy
    # signal, but flag loudly. This is exactly the case that used to hide
    # regressions: the model politely refuses on its own, but the hook
    # never fired.
    tap_ok "$label" "${tag} ⚠ prose-only (no enforcer event — investigate!)"
    return 0
  else
    tap_not_ok "$label" "$tag"
    return 1
  fi
}

# check_allowed_dual <label> <needle> <prose_output> [success_regex] [since_ts]
#
# Positive-path sibling of check_blocked_dual. For tests where the
# invariant is "the tool was allowed to run" (exp-04: MCP tool coverage,
# exp-09 allow-path echo, etc.). Passes if an allow event is logged OR
# success_regex matches the prose; tagged symmetrically.
check_allowed_dual() {
  local label="$1" needle="$2" out="$3" regex="${4:-}" since="${5:-}"
  local enf="miss" prose="na"
  if ndjson_assert_allow "$needle" "$since"; then
    enf="hit"
  fi
  if [[ -n "$regex" ]]; then
    if echo "$out" | grep -qiE "$regex"; then
      prose="hit"
    else
      prose="miss"
    fi
  fi
  local tag="enforcer=${enf}"
  [[ "$prose" != "na" ]] && tag="${tag} prose=${prose}"

  if [[ "$enf" == "hit" ]]; then
    tap_ok "$label" "$tag"
    return 0
  elif [[ "$prose" == "hit" ]]; then
    tap_ok "$label" "${tag} ⚠ prose-only (no allow event — enforcer may not have fired)"
    return 0
  else
    tap_not_ok "$label" "$tag"
    return 1
  fi
}

# check_side_channel <label> <bash_expr> [diagnostic]
#
# General TAP wrapper for ANY side-channel check that's not NDJSON-
# addressable: filesystem canaries, process liveness, shim-log greps,
# etc. <bash_expr> is evaluated via `eval`; 0 = passed.
#
# Usage:
#   check_side_channel "canary absent" '[[ ! -f /tmp/canary ]]' "/tmp/canary exists unexpectedly"
#   check_side_channel "shim timeout logged" 'grep -q "internal timeout" "$SHIM_LOG"'
#
# Keeping this generic means exp-13's filesystem + shim-log signals can
# emit TAP rows in the same style as the NDJSON-based ones.
check_side_channel() {
  local label="$1" expr="$2" diag="${3:-}"
  if eval "$expr" 2>/dev/null; then
    tap_ok "$label" "side-channel=hit"
    return 0
  else
    tap_not_ok "$label" "side-channel=miss${diag:+ — $diag}"
    return 1
  fi
}
