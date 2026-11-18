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

# section <agent> <heading>: the lines under "## <heading>", up to the next "## ".
section() { awk -v h="## $2" '/^## / { on = ($0 == h); next } on' "$A/$1.agent.md"; }
# auto <agent> <ERE>: the agent's "In an auto run" section matches the pattern.
auto() { section "$1" "In an auto run" | grep -qE -- "$2"; }

# ---------- the shared "In an auto run" rules ----------
for a in "${AGENTS[@]}"; do
  check "$a: In an auto run comes before Next step" '[ "$(grep -E "^## (In an auto run|Next step)$" $A/$a.agent.md | tr "\n" "|")" = "## In an auto run|## Next step|" ]'
  check "$a: auto run only when the prompt starts with AUTO RUN" 'auto $a "only when the prompt starts with \`AUTO RUN\`"'
  check "$a: never asks the user in an auto run" 'auto $a "Never ask the user"'
  check "$a: a reply from a stop is handled as in manual use" 'auto $a "reply from a stop"'
  check "$a: can't finish: Result blocked" 'auto $a "\*\*Result:\*\* blocked: <why>"'
  check "$a: ends with a Result line, not Next" 'auto $a "one \`\*\*Result:\*\*\` line"'
  check "$a: Next step points to the Result line in an auto run" 'section $a "Next step" | grep -q "In an auto run, end with the \*\*Result:\*\* line instead"'
done
# ---------- each agent's own auto-run rules ----------
check "requirements: no slug question, task state exists" 'auto requirements "skip the slug question"'
check "requirements: no grill-me; open questions stay in the file" 'auto requirements "grill-me" && auto requirements "## Open questions"'
check "planner: open questions don't stop it" 'auto planner "Skip step 1" && auto planner "still write the plan"'
check "planner: blocking questions become Requirement gaps: yes" 'auto planner "## Requirement gaps" && auto planner "\- Requirement gaps: yes"'
check "planner: Stop flags kept current on an update or a re-plan" 'auto planner "Keep the Stop flags current" && auto planner "update plan.md" && auto planner "Re-plan the review findings"'
check "implementer: a quick fix bigger than its estimate is routed to re-plan, left open" 'auto implementer "bigger than its estimate" && auto implementer "Route.* to \`re-plan\`" && auto implementer "Status.*\`open\`"'
check "reviewer: Decision from Recommend, a Route for each fix, no questions" 'auto reviewer "set \*\*Decision\*\* to the finding.s \*\*Recommend\*\*" && auto reviewer "\*\*Route\*\*" && auto reviewer "steps 7 and 8"'
check "reviewer: unclear findings stay _pending_" 'auto reviewer "Leave \`Decision: _pending_\`"'
check "reviewer: a blocker is never parked or skipped without the user" 'auto reviewer "\*\*blocker\*\* is recommended debt or skip"'
check "reviewer: debt still goes to tech-debt.md" 'auto reviewer "tech-debt.md"'
check "reviewer: each decision logged to auto-decisions.md in the router's format" 'auto reviewer "auto-decisions.md" && [ "$(for k in When What Why Rule; do auto reviewer "^  - \*\*$k:\*\*" && echo $k; done | wc -l)" -eq 4 ]'
check "shipper: the write-mr.md run does steps 1-3 only, no evidence check" 'auto shipper "\"Write mr.md for <task-id>. Don.t push or create the MR.\"" && auto shipper "steps 1–3 only" && auto shipper "Skip 1b"'
check "shipper: the ship run takes the pre-ship stop as the go-ahead, mr.md unchanged" 'auto shipper "\"Ship <task-id>. The user confirmed the push at the pre-ship stop.\"" && auto shipper "skip step 4" && auto shipper "don.t change mr.md"'
check "review-responder: triage commits FIX changes without an OK" 'auto review-responder "\"Triage <task-id>\"" && auto review-responder "without waiting for an OK"'
check "review-responder: ASK threads are left for the duo stop" 'auto review-responder "ASK.*duo stop"'
check "review-responder: triage returns even with no FIX items" 'auto review-responder "even with no FIX items"'
check "review-responder: push and reply needs no further go-ahead" 'auto review-responder "\"Push and reply <task-id>\"" && auto review-responder "no further go-ahead"'
check "evidence: no approval steps in an auto run; the pre-ship stop gives them" 'auto evidence "pre-ship stop"'

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
