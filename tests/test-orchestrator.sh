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

# ---------- stops ----------
check "stop: shows the DECISION NEEDED block, then ends the turn" 'sec "Stops" "^⏸ DECISION NEEDED: <stop-id>" && sec "Stops" "end your turn"'
check "stop: the reason word for word, with the files it names" 'sec "Stops" "<reason, word for word>"'
check "stop: the last stage's Result line, the only place a stalled stage says why" 'sec "Stops" "Last stage result: <" && sec "Stops" "stalled"'
check "stop: lists the replies it accepts" 'sec "Stops" "^- \`approve\`" && sec "Stops" "^- anything else"'
check "approval: only a reply that is nothing but an approval" 'sec "Answering a stop" "nothing but an approval" && sec "Answering a stop" "\`lgtm\`"'
check "approval: runs next-stage.sh <task-id> approve, then next-stage.sh again" 'sec "Answering a stop" "\`scripts/agent/next-stage.sh <task-id> approve\`" && sec "Answering a stop" "then run \`scripts/agent/next-stage.sh <task-id>\`"'
check "approval refused: its message word for word and the stop again" 'sec "Answering a stop" "exits 1" && sec "Answering a stop" "word for word" && sec "Answering a stop" "same stop block again"'
check "never approves for the user" 'sec "Answering a stop" "Never run .approve. without"'

# ---------- feedback: every stop the router raises has a stage to send it to ----------
# stop_ids: each stop id next-stage.sh can print (from its _stop and _unreadable calls).
stop_ids() { grep -oE '_(stop|unreadable) [a-z-]+ ' "$NS" | awk '{ print $2 }' | sort -u; }
# feedback_agent <stop-id>: the agent in that stop's row of the Feedback table.
feedback_agent() { section "Feedback" | awk -F'|' -v id="\`$1\`" '{ c = $2; gsub(/^ +| +$/, "", c) } c == id { print $3 }' | grep -oE '[a-z-]+' | head -n1; }
check "the router raises stops (the cross-check reads them)" '[ "$(stop_ids | wc -l)" -ge 9 ]'
for id in $(stop_ids); do
  check "feedback: the $id stop has a row" '[ -n "$(feedback_agent $id)" ]'
done
# feedback_agents_exist: each row's agent has an agent file (stalled names no fixed agent).
feedback_agents_exist() { local id a; for id in $(stop_ids); do [ "$id" = stalled ] && continue; a="$(feedback_agent "$id")"; [ -f "$A/$a.agent.md" ] || return 1; done; }
check "feedback: every agent in the table exists" 'feedback_agents_exist'
check "feedback: the stalled stop goes back to the agent its reason names" 'section Feedback | grep -E "^\| \`stalled\`" | grep -q "named at the start of the reason"'
check "feedback: pre-ship goes to evidence, or the shipper writing mr.md" 'section Feedback | grep -E "^\| \`pre-ship\`" | grep -q evidence && sec Feedback "Write mr.md for <task-id>. Don.t push or create the MR."'
check "feedback: the prompt carries the reply word for word" 'sec Feedback "AUTO RUN. The user replied at the <stop-id> stop for <task-id>: \"<reply, word for word>\""'
check "feedback: then next-stage.sh again" 'sec Feedback "run \`scripts/agent/next-stage.sh <task-id>\` again"'
check "retry or continue: next-stage.sh again, nothing sent to a stage" 'sec Feedback "\`retry\` or \`continue\`"'

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
