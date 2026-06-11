#!/usr/bin/env bash
# Experiment 04 — does PreToolUse fire for MCP tools (mcp__server__tool)?
#
# Hypothesis: yes, with full mcp__server__tool name.
#
# Pass criterion: the enforcer log shows tool=mcp__test__do_nothing.

set -euo pipefail

RESULTS="$(dirname "$0")/results"

# Trivial stdio MCP exposing a single tool.
cat > "$HOME/test-mcp.js" <<'EOF'
const readline = require("readline");
const rl = readline.createInterface({ input: process.stdin });
rl.on("line", (line) => {
  let msg;
  try { msg = JSON.parse(line); } catch { return; }
  const out = (body) => process.stdout.write(JSON.stringify(body) + "\n");
  if (msg.method === "initialize") {
    out({ jsonrpc: "2.0", id: msg.id,
          result: { protocolVersion: "2024-11-05",
                    capabilities: { tools: {} },
                    serverInfo: { name: "test", version: "0.0.1" } } });
  } else if (msg.method === "tools/list") {
    out({ jsonrpc: "2.0", id: msg.id,
          result: { tools: [{ name: "do_nothing", description: "no-op",
                              inputSchema: { type: "object", properties: {} } }] } });
  } else if (msg.method === "tools/call") {
    out({ jsonrpc: "2.0", id: msg.id,
          result: { content: [{ type: "text", text: "did nothing" }] } });
  }
});
EOF

cat > "$HOME/.mcp.json" <<EOF
{
  "mcpServers": {
    "test": {
      "command": "node",
      "args": ["$HOME/test-mcp.js"]
    }
  }
}
EOF

out=$(claude --dangerously-skip-permissions --print \
  "Use the test mcp server's do_nothing tool." 2>&1) || true

if grep -q "mcp__test__do_nothing\|tool=mcp__test" "$RESULTS/enforcer.log" 2>/dev/null; then
  echo "PASS — MCP tool name reached enforcer."
  exit 0
fi

echo "INDETERMINATE — no mcp__ trace in enforcer.log."
echo "Claude output tail:"; echo "$out" | tail -20
echo "Enforcer log tail:"; tail -10 "$RESULTS/enforcer.log" 2>/dev/null || true
exit 1
