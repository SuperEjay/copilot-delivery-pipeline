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
# The one copy of the rules every stage agent's "## In an auto run" section
# starts with, word for word. The agent file is the place a subagent surely
# reads, so each agent keeps a copy; this check keeps the copies the same.
# To change the shared rules, change them here and in all eight agents.
SHARED_AUTO_RUN="$(cat <<'EOF'
Follow this section only when the prompt starts with `AUTO RUN`. The orchestrator sent it, and `scripts/agent/next-stage.sh` decides what runs next from the files you write. Where this section conflicts with the steps above, it wins.
- **Never ask the user anything.** Write open questions and decisions into your files in `.work/<task-id>/` and return. Only the orchestrator talks to the user.
- **A reply from a stop:** if the prompt carries the user's reply from a stop, handle it as you would that reply in manual use.
- **Can't finish** (stuck, the plan is wrong, a script refuses): commit nothing, leave the `.work/` files the router reads as they are, and return `**Result:** blocked: <why>`. The run then stops for the user.
- **End with one `**Result:**` line** in place of the `**Next:**` line: one sentence on what you did and which file you wrote.
EOF
)"
SHARED_LINES="$(printf '%s\n' "$SHARED_AUTO_RUN" | wc -l | tr -d ' ')"
for a in "${AGENTS[@]}"; do
  check "$a: In an auto run comes before Next step" '[ "$(grep -E "^## (In an auto run|Next step)$" $A/$a.agent.md | tr "\n" "|")" = "## In an auto run|## Next step|" ]'
  check "$a: In an auto run starts with the shared rules, word for word" '[ "$(section $a "In an auto run" | head -n "$SHARED_LINES")" = "$SHARED_AUTO_RUN" ]'
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
# Evidence needs Verdict: READY. A fix that's verified, or a finding parked as
# debt or skipped, must not hold the Verdict at FIX FIRST.
check "reviewer: Verdict counts a fix only until its Status is verified" 'section reviewer Rules | grep -q "Decision \`fix\` and any Status but \`verified\`"'
check "reviewer: Verdict set again whenever a Decision or Status changes" 'section reviewer Rules | grep -q "Set the Verdict again whenever you change a Decision or a Status"'
check "reviewer: second pass sets the Verdict again" 'section reviewer Steps | grep -q "Second pass.*set the Verdict again"'
check "reviewer: in an auto run, the Verdict is set after deciding" 'auto reviewer "then set the Verdict"'
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
