#!/usr/bin/env bash
# Experiment 11 — measure Unix-socket RTT under synthetic load.
#
# The XPC path requires macOS, so this container-bound test establishes
# only the Linux socket baseline; the same script on macOS would swap in
# the XPC transport for comparison.
#
# Hypothesis: p99 < 10ms for a trivial allow decision.
# Pass criterion: p99 < 10ms across 200 back-to-back synthetic calls.

set -euo pipefail

SOCK="${UL_SOCKET:-$HOME/.userlayer/sockets/enforcer.sock}"
[[ -S "$SOCK" ]] || { echo "FAIL — no socket at $SOCK"; exit 1; }

python3 - "$SOCK" <<'PY'
import json, os, socket, sys, time
sock_path = sys.argv[1]
N = 200
samples = []
req = json.dumps({
  "proto": 1,
  "origin": "claude-code",
  "event": "PreToolUse",
  "sessionID": "bench",
  "toolName": "Bash",
  "toolInput": {"command": "ls"},
  "cwd": "/tmp",
  "permissionMode": "bypassPermissions",
  "capHint": "firewall.dev-assistant",
}) + "\n"
for _ in range(N):
  s = socket.socket(socket.AF_UNIX); s.connect(sock_path)
  t0 = time.perf_counter_ns()
  s.sendall(req.encode())
  buf = b""
  while b"\n" not in buf: buf += s.recv(4096)
  t1 = time.perf_counter_ns()
  samples.append((t1-t0)/1e6)
  s.close()
samples.sort()
p50 = samples[N//2]
p99 = samples[int(N*0.99)]
print(f"p50 = {p50:.2f}ms   p99 = {p99:.2f}ms   max = {samples[-1]:.2f}ms")
sys.exit(0 if p99 < 10 else 1)
PY
