#!/usr/bin/env bash
# Checks the eight stage agents' files: what they need to run as subagents in
# an auto run (ADR 0001), and that manual use keeps its handoffs.
# Usage: tests/test-agents.sh     (exit 0 = all passed)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
A="$ROOT/payload/.github/agents"
AGENTS=(requirements planner implementer verifier reviewer evidence shipper review-responder)
pass=0; fail=0
check() { if eval "$2"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; fi; }

# frontmatter <agent>: the lines between the file's first two "---" lines.
frontmatter() { awk 'NR == 1 && $0 == "---" { on = 1; next } on && $0 == "---" { exit } on' "$A/$1.agent.md"; }

# ---------- frontmatter ----------
for a in "${AGENTS[@]}"; do
  check "$a: include-custom-instructions: true in the frontmatter" 'frontmatter $a | grep -qx "include-custom-instructions: true"'
  check "$a: handoffs kept for manual use" 'frontmatter $a | grep -qx "handoffs:"'
done

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
