#!/usr/bin/env bash
# Checks the orchestrator's file (pipeline.agent.md) against the auto run's
# contract: next-stage.sh's verbs and stop ids (ADR 0001, issue #4).
# Usage: tests/test-orchestrator.sh     (exit 0 = all passed)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
A="$ROOT/payload/.github/agents"
O="$A/pipeline.agent.md"
NS="$ROOT/payload/scripts/agent/next-stage.sh"
pass=0; fail=0
check() { if eval "$2"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; fi; }

[ -f "$O" ] || { echo "FAIL: $O is missing"; echo "passed=0 failed=1"; exit 1; }

# frontmatter: the lines between the file's first two "---" lines.
frontmatter() { awk 'NR == 1 && $0 == "---" { on = 1; next } on && $0 == "---" { exit } on' "$O"; }
# section <heading>: the lines under "## <heading>", up to the next "## ".
section() { awk -v h="## $1" '/^## / { on = ($0 == h); next } on' "$O"; }
# sec <heading> <ERE>: that section matches the pattern.
sec() { section "$1" | grep -qE -- "$2"; }

# ---------- frontmatter ----------
check "name: pipeline" 'frontmatter | grep -qx "name: pipeline"'
check "model: the cheapest model" 'frontmatter | grep -qx "model: '"'"'GPT-6 Luna'"'"'"'
check "tools: read, search, execute, agent, and no edit" 'frontmatter | grep -qx "tools: \[.read., .search., .execute., .agent.\]"'
check "no handoffs: it drives the stages as subagents" '! frontmatter | grep -q "^handoffs:"'

# ---------- the loop ----------
check "runs next-stage.sh <task-id> and acts on the one line" 'sec "The loop" "scripts/agent/next-stage.sh <task-id>\`"'
check "run: the prompt goes on word for word" 'sec "The loop" "^- \`run <agent> <prompt>\`" && sec "The loop" "word for word"'
check "run: calls the stage by name, never vscode-agent-<hash>" 'sec "The loop" "by name" && sec "The loop" "vscode-agent-"'
check "run: names the stage's model from its model: line on every call" 'sec "The loop" "\`model:\` line" && sec "The loop" "every call"'
check "run: one progress line with the stage's Result line" 'sec "The loop" "▶ <agent>: <its \`\*\*Result:\*\*\` line>"'
check "run: one stage at a time" 'sec "The loop" "one at a time"'
check "run: no loop guard of its own; the stalled stop covers it" 'sec "The loop" "\`stalled\`"'
check "exit 1: pass on the script's message" 'sec "The loop" "exits 1"'

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
