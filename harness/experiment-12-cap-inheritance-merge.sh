#!/usr/bin/env bash
# Experiment 12 — offline merge-semantics check for cap inheritance.
#
# Not an integration test; this is a Python mirror of
# CapInheritanceResolver.mergeChain that exercises the set/extend/remove
# operators against hand-authored vectors. Run inside the container
# because Swift isn't available here.
#
# Pass criterion: all vectors match.

set -euo pipefail

python3 - <<'PY'
import sys

def merge(chain):
  """Python mirror of CapInheritanceResolver.mergeChain."""
  acc = {}
  for cap in chain:
    for k, op in cap["directives"].items():
      kind, val = op
      cur = acc.get(k)
      if kind == "set":
        acc[k] = val
      elif kind == "extend":
        if isinstance(cur, list) and isinstance(val, list):
          acc[k] = cur + val
        elif isinstance(cur, dict) and isinstance(val, dict):
          acc[k] = {**cur, **val}
        else:
          acc[k] = val
      elif kind == "remove":
        if isinstance(cur, list) and isinstance(val, list):
          drop = set(val); acc[k] = [x for x in cur if x not in drop]
        elif isinstance(cur, dict) and isinstance(val, list):
          acc[k] = {k2: v for k2, v in cur.items() if k2 not in set(val)}
  return acc

cases = [
  {
    "name": "set-overrides-parent",
    "chain": [
      {"directives": {"timeout": ("set", 10)}},
      {"directives": {"timeout": ("set", 30)}},
    ],
    "expect": {"timeout": 30},
  },
  {
    "name": "extend-appends-list",
    "chain": [
      {"directives": {"bash.deny": ("set", ["fs.rm-rf-root"])}},
      {"directives": {"bash.deny": ("extend", ["git.push-force-main"])}},
    ],
    "expect": {"bash.deny": ["fs.rm-rf-root", "git.push-force-main"]},
  },
  {
    "name": "remove-drops-list-entries",
    "chain": [
      {"directives": {"bash.deny": ("set", ["a", "b", "c"])}},
      {"directives": {"bash.deny": ("remove", ["b"])}},
    ],
    "expect": {"bash.deny": ["a", "c"]},
  },
  {
    "name": "extend-merges-dict",
    "chain": [
      {"directives": {"env": ("set", {"A": "1"})}},
      {"directives": {"env": ("extend", {"B": "2"})}},
    ],
    "expect": {"env": {"A": "1", "B": "2"}},
  },
  {
    "name": "remove-keys-from-dict",
    "chain": [
      {"directives": {"env": ("set", {"A": "1", "B": "2"})}},
      {"directives": {"env": ("remove", ["B"])}},
    ],
    "expect": {"env": {"A": "1"}},
  },
]

failed = 0
for c in cases:
  got = merge(c["chain"])
  ok = got == c["expect"]
  print(("✅" if ok else "❌"), c["name"])
  if not ok:
    print("  got   ", got)
    print("  expect", c["expect"])
    failed += 1

sys.exit(0 if failed == 0 else 1)
PY
