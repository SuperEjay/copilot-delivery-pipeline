#!/usr/bin/env bash
# Checks the eight stage agents' files: what they need to run as subagents in
# an auto run (ADR 0001), and that none has handoffs (ADR 0002: manual mode
# moves on through each agent's **Next:** line).
# Usage: tests/test-agents.sh     (exit 0 = all passed)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
A="$ROOT/payload/.github/agents"
NS="$ROOT/payload/scripts/agent/next-stage.sh"
pass=0; fail=0
check() { if eval "$2"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; fi; }

# ---------- the stage agents: one list, in next-stage.sh ----------
# The router's STAGE_AGENTS is the one list of stage agents; these tests read it.
read -r -a AGENTS <<< "$(sed -n 's/^STAGE_AGENTS="\(.*\)"$/\1/p' "$NS")"
check "next-stage.sh sets STAGE_AGENTS once" '[ "$(grep -c "^STAGE_AGENTS=" "$NS")" -eq 1 ] && [ "${#AGENTS[@]}" -gt 0 ]'
check "the router checks the agents in STAGE_AGENTS" 'grep -q "^for _agent in \$STAGE_AGENTS; do" "$NS"'
check "STAGE_AGENTS names every agent file but the orchestrator, no more" '[ "$(printf "%s\n" "${AGENTS[@]}" | sort | tr "\n" " ")" = "$(cd "$A" && ls *.agent.md | sed "s/\.agent\.md$//" | grep -vx pipeline | sort | tr "\n" " ")" ]'

# frontmatter <agent>: the lines between the file's first two "---" lines.
frontmatter() { awk 'NR == 1 && $0 == "---" { on = 1; next } on && $0 == "---" { exit } on' "$A/$1.agent.md"; }

# ---------- frontmatter ----------
for a in "${AGENTS[@]}"; do
  check "$a: include-custom-instructions: true in the frontmatter" 'frontmatter $a | grep -qx "include-custom-instructions: true"'
  check "$a: no handoffs (ADR 0002)" '! frontmatter $a | grep -q "^handoffs:"'
done

# section <agent> <heading>: the lines under "## <heading>", up to the next "## "
# outside a ~~~ fence (a template in the section may have its own headings).
section() { awk -v h="## $2" '/^~~~/ { fence = !fence } !fence && /^## / { on = ($0 == h); next } on' "$A/$1.agent.md"; }
# auto <agent> <ERE>: the agent's "In an auto run" section matches the pattern.
# (Read into a variable first: grep -q stopping early would break awk's pipe,
# which pipefail turns into a random failure.)
auto() { local t; t="$(section "$1" "In an auto run")"; grep -qE -- "$2" <<<"$t"; }

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
check "review-responder: a suggestion block goes through apply-suggestion.sh, never GitLab's button" 'section review-responder "Triage and fix (\"Triage <task-id>\")" | grep -q "apply-suggestion.sh <task-id> <thread-id>" && section review-responder "Triage and fix (\"Triage <task-id>\")" | grep -q "Never use GitLab.s \*\*Apply suggestion\*\*"'
check "review-responder: a verbatim suggestion gets its own reply" 'grep -q "Applied the suggestion in <short-sha>." "$A/review-responder.agent.md"'
check "review-responder: an open ASK thread keeps ASK without reading its code again (#98)" 'grep -q "Still waiting on you (round <n>)." "$A/review-responder.agent.md" && grep -q "Nothing new since round <n>" "$A/review-responder.agent.md"'
check "planner: an adopted branch ticks what its commits cover (ADR 0004)" 'section planner "Adopted branch" | grep -q "adopted-commits.md" && section planner "Adopted branch" | grep -q "Tick .- \[x\]."'
check "shipper: an adopted MR keeps its title and description (ADR 0004)" 'grep -q "adopted-mr.md" "$A/shipper.agent.md" && grep -q "description word for word" "$A/shipper.agent.md"'
check "evidence: no approval steps in an auto run; the pre-ship stop gives them" 'auto evidence "pre-ship stop"'

# ---------- "In an MR review" sections (ADR 0003) ----------
# The router's REVIEW_AGENTS lists the agents that have an MR review mode; it
# refuses to run an MR review while one lacks its section.
read -r -a REVIEW <<< "$(sed -n 's/^REVIEW_AGENTS="\(.*\)"$/\1/p' "$NS")"
check "next-stage.sh sets REVIEW_AGENTS once" '[ "$(grep -c "^REVIEW_AGENTS=" "$NS")" -eq 1 ] && [ "${#REVIEW[@]}" -gt 0 ]'
for a in "${REVIEW[@]}"; do
  check "$a: has an In an MR review section, after In an auto run and before Next step" '[ "$(grep -E "^## (In an auto run|In an MR review|Next step)$" $A/$a.agent.md | tr "\n" "|")" = "## In an auto run|## In an MR review|## Next step|" ]'
done
mr() { local t; t="$(section "$1" "In an MR review")"; grep -qE -- "$2" <<<"$t"; }
check "REVIEW_AGENTS has the requirements agent" 'printf "%s\n" "${REVIEW[@]}" | grep -qx requirements'
check "requirements: the router's spec prompts start it" 'mr requirements "Find the spec for mr-<iid>" && mr requirements "approved the MR description as the spec"'
check "requirements: looks in order: stored id, branch/title/description, commits" 'mr requirements "^1\. .*state_clickup_id|^1\. .*task state" && mr requirements "^2\. .*branch.*title.*description" && mr requirements "^3\. .*commit messages.*CU-<id>.*#<id>"'
check "requirements: reads the MR from mr.json" 'mr requirements "mr.json"'
check "requirements: never guesses" 'mr requirements "[Nn]ever guess"'
check "requirements: nothing found: Spec source: none, and return" 'mr requirements "Spec source: none"'
check "requirements: stores a found id, then fetches it" 'mr requirements "set-review-spec.sh <iid> <id>" && mr requirements "clickup.sh fetch mr-<iid>"'
check "requirements: the weak spec from the MR description" 'mr requirements "Spec source: MR description \(weak\)"'
check "requirements: a reply at the spec stop: an id or the ACs" 'mr requirements "spec stop" && mr requirements "Spec source: ACs from the user"'
check "requirements: always a Spec source line" 'mr requirements "always has a .Spec source:. line"'
check "requirements: no open questions; gaps become spec-gap findings" 'mr requirements "## Spec gaps" && mr requirements "spec-gap" && mr requirements "[Nn]o .## Open questions."'
check "requirements: never writes to ClickUp" 'mr requirements "[Nn]ever write to ClickUp"'
check "REVIEW_AGENTS has the reviewer" 'printf "%s\n" "${REVIEW[@]}" | grep -qx reviewer'
check "reviewer: the router's prompts start it" 'mr reviewer "\"Review mr-<iid>.\"" && mr reviewer "Post the findings marked post for mr-<iid>"'
check "reviewer: the MR's open threads first, through fetch-duo-review.sh" 'mr reviewer "fetch-duo-review.sh mr-<iid>" && mr reviewer "threads.json"'
check "reviewer: doesn't repeat a raised point; +1 only with new evidence" 'mr reviewer "already raised" && mr reviewer "\+1, see thread" && mr reviewer "new evidence"'
check "reviewer: signals from the worktree, against the target branch" 'mr reviewer "review-signals.sh mr-<iid>" && mr reviewer "review worktree"'
check "reviewer: failed checks are high-severity findings" 'mr reviewer "verification.md" && mr reviewer "Result: FAIL" && mr reviewer "blocker or major"'
check "reviewer: spec gaps are spec-gap findings, and a weak spec is said" 'mr reviewer "spec-gap" && mr reviewer "Spec gaps" && mr reviewer "weak"'
check "reviewer: respects the focus" 'mr reviewer "focus.md" && mr reviewer "most churn"'
check "reviewer: post, debt or skip, no fix and no route" 'mr reviewer "\*\*post\*\*, \*\*debt\*\* or \*\*skip\*\*" && mr reviewer "no fix"'
check "reviewer: the template has Decision: post | debt | skip" 'mr reviewer "^- \*\*Decision:\*\* post \| debt \| skip$"'
check "reviewer: debt goes to tech-debt.md" 'mr reviewer "tech-debt.md"'
check "reviewer: posts one at a time through post-review-thread.sh" 'mr reviewer "post-review-thread.sh <iid> CR-n" && mr reviewer "one at a time"'
check "reviewer: a declined post becomes skip" 'mr reviewer "declines" && mr reviewer "Decision.*skip"'
check "reviewer: never resolves threads, never changes the MR" 'mr reviewer "[Nn]ever resolve" && mr reviewer "[Nn]ever change"'
check "reviewer: re-review: each posted finding verified or still open" 'mr reviewer "[Rr]e-review" && mr reviewer "Status:\*\* verified" && mr reviewer "Status:\*\* open"'
check "reviewer: re-review: new code gets new CR numbers, decisions aren't reopened" 'mr reviewer "new CR numbers" && mr reviewer "[Dd]on.t reopen"'
check "reviewer: the reply prompt: reply-thread.sh, never --resolve, record Replied" 'mr reviewer "Reply on the threads of the findings verified for mr-<iid>" && mr reviewer "reply-thread.sh mr-<iid> <thread-id>" && mr reviewer "never with .--resolve." && mr reviewer "Replied:\*\* yes" && mr reviewer "Replied:\*\* declined"'
check "verifier: in an MR review, the router's prompt starts it" 'mr verifier "Run the checks for mr-<iid> in its review worktree"'
check "verifier: runs every check once through run-checks.sh" 'mr verifier "scripts/agent/run-checks.sh mr-<iid> all" && mr verifier "once"'
check "verifier: Commit is the CHECKED sha, not your HEAD" 'mr verifier "CHECKED <sha>" && mr verifier "Commit:.*CHECKED"'
check "verifier: each failing check with its failing lines, for the reviewer" 'mr verifier "failing lines" && mr verifier "high-severity finding"'
check "verifier: read-only: no tests added, nothing changed or committed" 'mr verifier "[Nn]ever change, add or commit anything"'
check "verifier: failures are findings, not fixes" 'mr verifier "finding, not a fix"'
check "verifier: ACs are left to the reviewer" 'mr verifier "reviewer grades the acceptance criteria"'

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
