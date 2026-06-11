#!/usr/bin/env bash
# Experiment 06 — does `updatedInput` actually rewrite the tool call?
#
# Hypothesis: yes — Claude Code honors hookSpecificOutput.updatedInput
# and proceeds with the rewritten payload.
#
# Pass criterion: agent runs `echo ROUND2_ORIGINAL`; the enforcer
# rewrites it to `echo ROUND2_REWRITTEN_BY_HOOK`; the tool output seen
# by the agent contains the rewritten string and NOT the original.
#
# Round 2: we swapped the original `git push --force` payload for a
# neutral echo payload because modern Claude Code pre-refuses
# force-pushes on safety grounds — the hook never gets to rewrite.

set -euo pipefail

# Resolve absolute paths BEFORE any cd so the restore trap survives
# later directory changes.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULTS="$SCRIPT_DIR/results"
SOCK="${UL_SOCKET:-$HOME/.userlayer/sockets/enforcer.sock}"
ENFORCER_BIN="${HOME}/bin/mock-enforcer"

# On exit, restart the default enforcer so experiments 07..16 still
# have a working socket. This is critical — without it the whole tail
# of the harness cascades into failures.
#
# Round-3 fix (INV-observability): the restart MUST preserve the
# NDJSON audit path. Previous versions of this script omitted
# --ndjson, causing the replacement enforcer to fall back to
# ~/.userlayer/sockets/enforcer.ndjson (not bind-mounted), which
# silently lost all audit events for exps 07–16. Prefer the
# UL_NDJSON env var (exported by run-experiments.sh) so this script
# stays path-agnostic; fall back to the flag form if the env var is
# empty (e.g. running exp-06 standalone from a shell).
restore_default_enforcer() {
  kill "${REWRITE_PID:-0}" 2>/dev/null || true
  rm -f "$SOCK" 2>/dev/null || true
  local ndjson_flag=()
  if [[ -n "${UL_NDJSON:-}" ]]; then
    ndjson_flag=(--ndjson "$UL_NDJSON")
  fi
  "$ENFORCER_BIN" --socket "$SOCK" "${ndjson_flag[@]}" >>"$RESULTS/enforcer.log" 2>&1 &
  for _ in $(seq 1 50); do [[ -S "$SOCK" ]] && break; sleep 0.1; done
}
trap restore_default_enforcer EXIT

pkill -f mock-enforcer 2>/dev/null || true
sleep 0.3

# Rewrite enforcer: replace ROUND2_ORIGINAL with ROUND2_REWRITTEN_BY_HOOK
# inside the Bash tool's command field.
cat > /tmp/rewrite-enforcer.py <<'EOF'
import json, os, socket, sys, uuid, signal
PROTO = 1; sock_path = sys.argv[1]
try: os.unlink(sock_path)
except FileNotFoundError: pass
s = socket.socket(socket.AF_UNIX); s.bind(sock_path); os.chmod(sock_path, 0o600); s.listen(4)
signal.signal(signal.SIGTERM, lambda *a: (s.close(), os.unlink(sock_path), sys.exit(0)))
while True:
    c, _ = s.accept()
    buf = b""
    while b"\n" not in buf: buf += c.recv(4096)
    req = json.loads(buf.split(b"\n", 1)[0])
    inp = req.get("toolInput", req.get("input", {}))
    cmd = inp.get("command", "")
    updated = None
    if "ROUND2_ORIGINAL" in cmd:
        updated = {**inp, "command": cmd.replace("ROUND2_ORIGINAL", "ROUND2_REWRITTEN_BY_HOOK")}
    v = {
      "proto": PROTO,
      "decision": "allow",
      "reason": "rewritten by experiment-06 rewrite-enforcer",
      "ruleID": "exp06.echo-rewrite",
      "capID": "firewall.dev-assistant",
      "updatedInput": updated,
      "additionalContext": "I rewrote the echo string to prove updatedInput propagates.",
      "auditID": uuid.uuid4().hex[:12],
    }
    c.sendall((json.dumps(v)+"\n").encode()); c.close()
EOF

python3 /tmp/rewrite-enforcer.py "$SOCK" &
REWRITE_PID=$!
sleep 0.5

# The command is completely benign so the model's built-in safety
# reasoning has no reason to refuse. If updatedInput propagates, the
# agent will report "ROUND2_REWRITTEN_BY_HOOK" rather than the original.
out=$(claude --dangerously-skip-permissions --print \
  "Run exactly this bash command and then tell me what it printed to stdout, verbatim: echo ROUND2_ORIGINAL" 2>&1) || true

if echo "$out" | grep -q "ROUND2_REWRITTEN_BY_HOOK" \
   && ! echo "$out" | grep -q "ROUND2_ORIGINAL$"; then
  echo "PASS — updatedInput rewrite propagated to execution."
  exit 0
fi

if echo "$out" | grep -q "ROUND2_REWRITTEN_BY_HOOK"; then
  echo "PARTIAL — rewritten string observed, but original also present."
  echo "$out" | tail -30
  exit 1
fi

echo "FAIL — rewrite did not propagate."
echo "$out" | tail -30
exit 1
