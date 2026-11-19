#!/usr/bin/env bash
# Tests next-stage.sh, the auto run's router, in a scratch repo with a local
# bare remote: fixture .work/ files for each stage, and the one line it prints
# (run / stop / end) or what `approve` accepts.
# Usage: tests/test-next-stage.sh     (exit 0 = all passed)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
check() { if eval "$2"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; cat "$T/out.txt" 2>/dev/null | sed 's/^/      /'; fi; }
S=scripts/agent

# ---------- scratch repo ----------
git init -q --bare -b main "$T/remote.git"
git init -q -b main "$T/proj"; cd "$T/proj"
git config user.email t@t; git config user.name t
git remote add origin "$T/remote.git"
mkdir -p scripts .github; cp -r "$ROOT/payload/scripts/agent" scripts/
cp -r "$ROOT/payload/.github/agents" .github/   # next-stage.sh checks the stage agents first
printf '.work/\n.agent.env\n' > .gitignore
echo one > a.txt; git add -A; git commit -qm init; git push -q origin main
: > .agent.env   # MAX_AUTO_FIX_ROUNDS stays at its default, 2
W=.work/T1

# commit_change: move HEAD.  verify PASS|FAIL: verification.md at HEAD (PASS also
# records the verified commit, as run-checks.sh all does).
commit_change() { echo x >> a.txt; git commit -qam change; }
verify() {
  printf '# Verification: T1\nResult: %s\nCommit: %s\n' "$1" "$(git rev-parse HEAD)" > $W/verification.md
  if [ "$1" = PASS ]; then git rev-parse HEAD > $W/verified-head; else rm -f $W/verified-head; fi
}

# mark_reviewed: the reviewer reviewed HEAD (what review-signals.sh --mark-reviewed records).
mark_reviewed() { bash -c 'source scripts/agent/config.sh; state_set_reviewed_sha T1 "$(git rev-parse HEAD)"'; }
# review_md "<decision> <route> <status>"...: code-review.md with one finding per argument.
review_md() {
  local i=0 f d r st
  { echo "# Code review: T1"; echo "Verdict: FIX FIRST"; echo "## Findings"
    for f in "$@"; do
      i=$((i + 1)); read -r d r st <<< "$f"
      echo "### CR-$i · major · Correctness · \`a.txt:$i\`"
      echo "- **Problem:** p"; echo "- **Effort:** S · **Recommend:** fix"
      echo "- **Decision:** $d · **Route:** $r"; echo "- **Status:** $st"
    done
  } > $W/code-review.md
}

# evidence_md [sha]: an evidence manifest captured at this commit (default HEAD).
evidence_md() {
  mkdir -p $W/evidence; echo "AC-1 output" > $W/evidence/AC-1.md
  printf '# Evidence: T1\nCommit: %s\n- [x] AC-1 · `AC-1.md` · works\n' "${1:-$(git rev-parse HEAD)}" > $W/evidence/evidence.md
}

# approve_evidence: what the user's approve-evidence.sh records.  mr_opened: what create-mr.sh records.
approve_evidence() { bash -c 'source scripts/agent/config.sh; source scripts/agent/evidence-lib.sh; approval_write T1 AC-1.md'; }
mr_opened() { bash -c 'source scripts/agent/config.sh; state_set_mr_iid T1 7'; }

# duo_round <n>: what fetch-duo-review.sh records for a new Duo round.
duo_round() { bash -c 'source scripts/agent/config.sh; state_set_review T1 "$1" "ids$1"' _ "$1"; }
# triage_md <round> <replied yes|no> <verdict>...: review-triage.md with one thread per verdict.
triage_md() {
  local round="$1" replied="$2" v i=0; shift 2
  { echo "# Duo review triage: T1"; echo "Round: $round"; [ "$replied" = yes ] && echo "Replied: yes"
    echo "| Thread | File:line | Verdict | Reason | Commit |"; echo "|---|---|---|---|---|"
    for v in "$@"; do i=$((i + 1)); echo "| d$i | a.txt:$i | $v | r | |"; done
  } > $W/review-triage.md
}

# next <args>: run next-stage.sh, output in $T/out.txt and $out, exit code in $rc.
next() { $S/next-stage.sh "$@" > "$T/out.txt" 2>&1; rc=$?; out="$(cat "$T/out.txt")"; }

# ---------- no task state ----------
next T1
check "no task state: exit 1, pointing at /start-task" '[ $rc -eq 1 ] && grep -q "/start-task" "$T/out.txt"'

$S/start-task.sh T1 router > "$T/out.txt" 2>&1

# ---------- the stage agents know an auto run (an old or kept agent file doesn't) ----------
AG=.github/agents
cp $AG/planner.agent.md "$T/planner.keep"
sed -i '/^## In an auto run$/d' $AG/planner.agent.md
cp "$T/planner.keep" $AG/planner.agent.md.new   # what install.sh --update writes next to a kept file
next T1
check "a stage agent without the auto-run section: exit 1, naming it and its .new" '[ $rc -eq 1 ] && grep -qF "$AG/planner.agent.md" "$T/out.txt" && grep -qF "planner.agent.md.new" "$T/out.txt"'
check "no decision is recorded for it" '[ ! -f $W/status.md ]'
next T1 approve
check "approve checks the agents too" '[ $rc -eq 1 ] && grep -qF "$AG/planner.agent.md" "$T/out.txt"'
rm $AG/planner.agent.md.new; next T1
check "no .new next to it: exit 1, naming it, pointing at --update rather than a .new" '[ $rc -eq 1 ] && grep -qF "$AG/planner.agent.md" "$T/out.txt" && ! grep -qF ".new" "$T/out.txt" && grep -q -- "--update" "$T/out.txt"'
rm $AG/planner.agent.md; next T1
check "a missing stage agent: exit 1, naming it" '[ $rc -eq 1 ] && grep -qF "$AG/planner.agent.md" "$T/out.txt" && ! grep -qF ".new" "$T/out.txt"'
cp "$T/planner.keep" $AG/planner.agent.md
sed -i '/^## In an auto run$/d' $AG/pipeline.agent.md 2>/dev/null
next T1
check "only the eight stage agents are checked, not the orchestrator" '[ $rc -eq 0 ]'
cp "$ROOT/payload/.github/agents/pipeline.agent.md" $AG/; rm -f $W/status.md

# ---------- requirements: always stops ----------
next T1
check "no requirements.md: run the requirements agent" '[ $rc -eq 0 ] && [ "$out" = "run requirements AUTO RUN. Analyse T1." ]'
printf '# T1: Export\n## Acceptance criteria\n- AC-1: x\n' > $W/requirements.md
next T1
check "requirements.md written: stop for the user" '[ $rc -eq 0 ] && [[ "$out" == "stop requirements "*"requirements.md"* ]]'
check "status.md records the pending stop" 'grep -q "^Pending stop: requirements " $W/status.md'

# ---------- approve: tied to what the stop was about ----------
echo "- AC-2: y" >> $W/requirements.md
next T1 approve
check "approve refuses a stop that changed since it was shown" '[ $rc -eq 1 ] && grep -q "changed" "$T/out.txt"'
next T1; next T1 approve
check "approve records the shown stop" '[ $rc -eq 0 ] && grep -q "^Approved requirements: " $W/status.md'
next T1
check "approved requirements: run the planner" '[ "$out" = "run planner AUTO RUN. Plan T1." ]'
next T1 approve
check "approve with no pending stop: exit 1" '[ $rc -eq 1 ] && grep -q "No stop" "$T/out.txt"'
echo "- AC-3: z" >> $W/requirements.md
next T1
check "requirements changed after approval: the stop repeats" '[[ "$out" == "stop requirements "* ]]'
next T1; next T1 approve; next T1
check "approved again: on to the planner" '[ "$out" = "run planner AUTO RUN. Plan T1." ]'

# ---------- run.log: one line per decision and approval (ADR 0002) ----------
# "<UTC time> <run|stop|end|approve> <agent or stop id, - for end> round=<n>/<max> head=<short HEAD>"
$S/start-task.sh T3 runlog > "$T/out.txt" 2>&1
L=.work/T3/run.log
HEAD7="$(git rev-parse --short HEAD)"
# log_line <n>: line n of T3's run.log, with the time checked and cut off.
log_line() { sed -n "${1}p" $L | sed -nE 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z //p'; }
log_count() { [ -f $L ] && wc -l < $L | tr -d ' ' || echo 0; }
check "no run.log before the first decision" '[ ! -f $L ]'
next T3
check "run: logged with the agent, the fix round and HEAD" '[ "$(log_line 1)" = "run requirements round=0/2 head=$HEAD7" ]'
printf '# T3: Export\n## Acceptance criteria\n- AC-1: x\n' > .work/T3/requirements.md
next T3
check "stop: logged with the stop id" '[ "$(log_line 2)" = "stop requirements round=0/2 head=$HEAD7" ]'
echo "- AC-2: y" >> .work/T3/requirements.md
next T3 approve
check "a refused approval logs nothing" '[ $rc -eq 1 ] && [ "$(log_count)" -eq 2 ]'
next T3; next T3 approve
check "approve: logged with the stop id, after the stop it approves" '[ "$(log_line 3)" = "stop requirements round=0/2 head=$HEAD7" ] && [ "$(log_line 4)" = "approve requirements round=0/2 head=$HEAD7" ]'
next T3 approve
check "approve with no stop pending logs nothing" '[ $rc -eq 1 ] && [ "$(log_count)" -eq 4 ]'
next T3
check "lines are only ever appended" '[ "$(log_count)" -eq 5 ] && [ "$(log_line 5)" = "run planner round=0/2 head=$HEAD7" ]'
check "status.md doesn't change because of run.log" '! grep -q "run.log" .work/T3/status.md'
git switch -q "$(bash -c 'source scripts/agent/config.sh; state_branch T1')"   # start-task.sh switched to T3's branch

# ---------- plan: stops only on a flag or more than 6 slices ----------
# plan_md <slices> [gaps] [migration] [flag] [team]: a plan with unchecked S slices.
plan_md() {
  local i
  { echo "# Plan: T1"; echo "## Slices"
    for i in $(seq 1 "$1"); do echo "- [ ] S$i: slice $i"; echo "  - Files: \`a.txt\`"; done
    echo "## Stop flags"
    echo "- Requirement gaps: ${2:-no}"; echo "- Migration: ${3:-no}"
    echo "- Feature flag: ${4:-no}"; echo "- Other team: ${5:-no}"
  } > $W/plan.md
}
# A plan with no Stop flags heading at all (v2 dropped the separate check for
# v1.1.0 tasks, ADR 0002): the same plan stop as a missing line.
printf '# Plan: T1\n## Slices\n- [ ] S1: one\n' > $W/plan.md
next T1
check "plan.md with no Stop flags heading: stop plan, naming the missing line" '[ $rc -eq 0 ] && [[ "$out" == "stop plan "*"Requirement gaps"* ]]'
printf '# Plan: T1\n## Slices\n- [ ] S1: one\n## Stop flags\n- Migration: no\n' > $W/plan.md
next T1
check "Stop flags heading missing a line: stop plan, naming the missing line" '[[ "$out" == "stop plan "*"Requirement gaps"* ]]'
next T1 approve
check "an unreadable plan can't be approved" '[ $rc -eq 1 ]'
plan_md 3 no yes
next T1
check "a migration flag stops the plan" '[[ "$out" == "stop plan "*"Migration"* ]]'
check "no auto-decision for a plan that stops" '[ ! -f $W/auto-decisions.md ]'
R=scripts/agent/next-stage.sh
check "the slice limit is set once, as MAX_PLAN_SLICES" '[ "$(grep -c "^MAX_PLAN_SLICES=6$" $R)" -eq 1 ] && ! grep -qE "gt 6|than 6|6 or fewer|^#.* 6 S slices" $R'
plan_md 6
next T1
check "6 slices go on, as an auto-decision" '[[ "$out" == "run implementer "* ]] && grep -q "6 or fewer slices" $W/auto-decisions.md'
rm $W/auto-decisions.md
plan_md 7
next T1
check "7 slices stop the plan" '[[ "$out" == "stop plan "*"7 slices (more than 6)"* ]]'
next T1 approve; next T1
check "an approved plan goes on" '[[ "$out" != stop* ]] && [ ! -f $W/auto-decisions.md ]'
sed -i 's/^- \[ \] S1:/- [x] S1:/' $W/plan.md; next T1
check "a ticked slice doesn't bring the approved plan's stop back" '[[ "$out" == "run implementer "* ]]'
sed -i 's/^- \[ \] S2:/- [X] S2:/' $W/plan.md; next T1
check "nor does a second one" '[[ "$out" == "run implementer "* ]]'
sed -i 's/^- \[ \] S7: slice 7/- [ ] S7: slice 7 (changed)/' $W/plan.md; next T1
check "a changed slice does bring it back" '[[ "$out" == "stop plan "*"7 slices"* ]]'
plan_md 3
next T1
BUILD="run implementer AUTO RUN. Build T1: implement the next unchecked slice in plan.md."
check "a plan with no flags goes on to the implementer" '[ "$out" = "$BUILD" ]'
check "and records the auto-decision under the Plan rule" '[ "$(grep -c "Plan accepted without a stop" $W/auto-decisions.md)" -eq 1 ] && grep -q "Rule:.*Plan" $W/auto-decisions.md'
next T1
check "the auto-decision is recorded once per plan" '[ "$(grep -c "Plan accepted without a stop" $W/auto-decisions.md)" -eq 1 ]'
echo "- AC-4: w" >> $W/requirements.md
next T1; next T1 approve; next T1
check "requirements changed after the plan: run the planner to update it" '[ "$out" = "run planner AUTO RUN. Requirements for T1 changed; update plan.md." ]'
next T1
check "the planner changed nothing for the new requirements: stop stalled, offering to keep the plan" '[[ "$out" == "stop stalled planner "*"keep plan.md as it is"* ]]'
next T1 approve; next T1
check "approved: the plan is kept for the new requirements, no planner loop" '[ "$out" = "run implementer AUTO RUN. Build T1: implement the next unchecked slice in plan.md." ]'
plan_md 4
next T1
check "updated plan: accepted again" '[ "$out" = "$BUILD" ] && [ "$(grep -c "Plan accepted without a stop" $W/auto-decisions.md)" -eq 2 ]'

# ---------- slices ----------
sed -i 's/^- \[ \] S1:/- [x] S1:/; s/^- \[ \] S2:/- [x] S2:/; s/^- \[ \] S3:/- [x] S3:/' $W/plan.md
next T1
check "one slice left: still the implementer" '[ "$out" = "$BUILD" ]'
check "ticked slices don't add another plan auto-decision" '[ "$(grep -c "Plan accepted without a stop" $W/auto-decisions.md)" -eq 2 ]'
sed -i 's/^- \[ \] S4:/- [x] S4:/' $W/plan.md
next T1
check "every slice ticked: not the implementer" '[ "$out" != "$BUILD" ]'
printf '## Review slices\n- [ ] R1: fix CR-2\n' >> $W/plan.md
next T1
check "an unchecked review slice: the implementer" '[ "$out" = "$BUILD" ]'
sed -i 's/^- \[ \] R1:/- [x] R1:/' $W/plan.md

# ---------- verify, and the fix-round limit ----------
VERIFY="run verifier AUTO RUN. Verify T1."
FIX="run implementer AUTO RUN. Fix the verification failures for T1 (see verification.md)."
next T1
check "all slices built: run the verifier" '[ "$out" = "$VERIFY" ]'
verify FAIL; next T1
check "FAIL at HEAD: back to the implementer, fix round 1" '[ "$out" = "$FIX" ] && grep -qx "Fix round: 1/2" $W/status.md'
next T1
check "the same run again with nothing changed: stop stalled" '[[ "$out" == "stop stalled implementer "* ]]'
check "and the round isn't counted twice" 'grep -qx "Fix round: 1/2" $W/status.md'
next T1
check "asked again without an approval: still stalled" '[[ "$out" == "stop stalled implementer "* ]]'
check "run.log grows on each call, and the stall is still seen (run.log isn't an input)" '[ "$(grep -c " stop stalled " $W/run.log)" -ge 2 ]'
commit_change; next T1
check "HEAD moved since the FAIL: verify again" '[ "$out" = "$VERIFY" ]'
verify FAIL; next T1
check "second FAIL: fix round 2" '[ "$out" = "$FIX" ] && grep -qx "Fix round: 2/2" $W/status.md'
commit_change; verify FAIL; next T1
check "third FAIL: stop at MAX_AUTO_FIX_ROUNDS (default 2)" '[[ "$out" == "stop fix-limit "*"2 fix rounds"* ]]'
next T1 approve; next T1
check "approving the fix-limit stop allows another round" '[ "$out" = "$FIX" ] && grep -qx "Fix round: 1/2" $W/status.md'
next T1
next T1 approve; next T1
check "approving the stalled stop runs the stage once more" '[ "$out" = "$FIX" ]'
check "approving the stalled stop doesn't start the fix rounds over" 'grep -qx "Fix round: 1/2" $W/status.md'
next T1
check "still nothing changed: stalled again" '[[ "$out" == "stop stalled implementer "* ]]'
printf '# Verification: T1\nResult: FAIL\n' > $W/verification.md
next T1
check "verification.md without a Commit line: a stop no approval passes" '[[ "$out" == "stop verify "*"Commit:"* ]] && { next T1 approve; [ $rc -eq 1 ]; }'
commit_change; verify PASS; rm $W/verified-head; next T1
check "PASS without the verified commit recorded: verify again" '[ "$out" = "$VERIFY" ]'
verify PASS; next T1
check "PASS at the verified commit: past the verifier" '[ "$out" != "$VERIFY" ] && [ "$out" != "$FIX" ]'

# ---------- code review ----------
REVIEW="run reviewer AUTO RUN. Review T1."
QUICK="run implementer AUTO RUN. Fix the review findings for T1 (Decision: fix, Route: quick, Status: open in code-review.md)."
check "verified, not reviewed at HEAD: run the reviewer" '[ "$out" = "$REVIEW" ]'
mark_reviewed; next T1
check "reviewed at HEAD but no code-review.md: a stop no approval passes" '[[ "$out" == "stop review "*"code-review.md"* ]] && { next T1 approve; [ $rc -eq 1 ]; }'
review_md "fix quick open" "debt _ open" "skip _ open"
next T1
check "an open quick fix: back to the implementer, a fix round on the same count as verify" '[ "$out" = "$QUICK" ] && grep -qx "Fix round: 2/2" $W/status.md'
commit_change; verify PASS; next T1
check "after the fix: verify passed, a delta review" '[ "$out" = "$REVIEW" ]'
mark_reviewed; review_md "fix quick fixed" "_pending_ _(set_if_fix)_ open"
next T1
check "a finding without a decision: stop review" '[[ "$out" == "stop review "*"CR-2"* ]]'
next T1 approve
check "approve refuses while a finding has no decision" '[ $rc -eq 1 ] && grep -q "CR-2" "$T/out.txt"'
review_md "fix quick verified" "fix _(set_if_fix)_ open"
next T1
check "an open fix without a route: stop review" '[[ "$out" == "stop review "*"CR-2"* ]]'
review_md "fix quick verified" "fix re-plan open"
next T1
check "a re-plan route: stop review" '[[ "$out" == "stop review "*"re-plan"* ]]'
next T1 approve; next T1
check "approved: the planner adds review slices" '[ "$out" = "run planner AUTO RUN. Re-plan the review findings for T1 (Route: re-plan in code-review.md)." ]'
review_md "fix re-plan open" "fix requirements open"
next T1; next T1 approve; next T1
check "a requirements route goes furthest back: the requirements agent" '[ "$out" = "run requirements AUTO RUN. Update requirements for T1 from the code review (Route: requirements in code-review.md)." ]'
review_md "fix quick open"; next T1
check "after approving a review stop, another quick fix: the count started over, fix round 1" 'grep -qx "Fix round: 1/2" $W/status.md'
commit_change; verify PASS; mark_reviewed
review_md "fix quick verified" "debt _ open" "skip _ open"
next T1
check "settled review: past the reviewer, fix rounds start over" '[ "$out" != "$REVIEW" ] && [[ "$out" != "stop review"* ]] && grep -qx "Fix round: 0/2" $W/status.md'

# ---------- evidence ----------
EVIDENCE="run evidence AUTO RUN. Capture evidence for T1."
check "settled review: capture evidence" '[ "$out" = "$EVIDENCE" ]'
mkdir -p $W/evidence; printf '# Evidence: T1\n- [ ] AC-1 · `AC-1.md` · works\n' > $W/evidence/evidence.md
next T1
check "evidence.md without a Commit line: a stop no approval passes" '[[ "$out" == "stop evidence "*"Commit:"* ]] && { next T1 approve; [ $rc -eq 1 ]; }'
evidence_md 0000000000000000000000000000000000000000; next T1
check "evidence captured at another commit: capture again" '[ "$out" = "$EVIDENCE" ]'
evidence_md; next T1
check "evidence at HEAD: past the evidence agent" '[ "$out" != "$EVIDENCE" ] && [[ "$out" != "stop evidence"* ]]'

# ---------- the pre-ship stop, and the shipper in two steps ----------
check "evidence at HEAD, no mr.md: the shipper writes it without pushing" '[ "$out" = "run shipper AUTO RUN. Write mr.md for T1. Don'"'"'t push or create the MR." ]'
printf 'Export invoices\n## What & why\nx\n' > $W/mr.md
next T1
check "mr.md written: the one pre-ship stop" '[[ "$out" == "stop pre-ship "*"evidence.md"*"mr.md"*"auto-decisions.md"*"approve-evidence.sh"* ]]'
next T1 approve
check "approve refuses until the evidence is approved" '[ $rc -eq 1 ] && grep -q "approve-evidence.sh" "$T/out.txt"'
sed -i 's/^- \[x\] AC-1/- [ ] AC-1/' $W/evidence/evidence.md; next T1
sed -i 's/^- \[ \] AC-1/- [x] AC-1/' $W/evidence/evidence.md
approve_evidence; next T1 approve
check "evidence ticked and approved after the stop was shown: one approve passes" '[ $rc -eq 0 ] && grep -q "^Approved pre-ship: " $W/status.md'
next T1
check "approved with the evidence approved: the shipper ships" '[ "$out" = "run shipper AUTO RUN. Ship T1. The user confirmed the push at the pre-ship stop." ]'
echo "retaken" > $W/evidence/AC-1.md; echo "- note" >> $W/evidence/evidence.md; next T1
check "evidence.md changed beyond its ticks after approval: the pre-ship stop again" '[[ "$out" == "stop pre-ship "* ]]'
approve_evidence; next T1; next T1 approve; next T1
check "approved again: the shipper ships" '[ "$out" = "run shipper AUTO RUN. Ship T1. The user confirmed the push at the pre-ship stop." ]'
echo "- CR-9: decided after the stop" >> $W/auto-decisions.md; next T1
check "auto-decisions.md changed after approval: the pre-ship stop again" '[[ "$out" == "stop pre-ship "* ]]'
next T1 approve; next T1
check "approved with the new auto-decision: the shipper ships" '[ "$out" = "run shipper AUTO RUN. Ship T1. The user confirmed the push at the pre-ship stop." ]'
mr_opened; next T1
check "MR open: the run ends until Duo has reviewed" '[ "$out" = "end MR open. Run /fetch-review T1 after Duo has reviewed it." ]'
check "end: logged with - for the id" 'tail -n1 $W/run.log | grep -qE "^[0-9TZ:-]+ end - round=[0-9]+/2 head=[0-9a-f]+$"'

# ---------- the Duo round ----------
TRIAGE="run review-responder AUTO RUN. Triage T1."
PUSH="run review-responder AUTO RUN. Push and reply T1."
duo_round 1; next T1
check "a new Duo round: triage it" '[ "$out" = "$TRIAGE" ]'
triage_md 1 no FIX ASK; commit_change; next T1
check "triaged with a fix committed: re-verify" '[ "$out" = "run verifier AUTO RUN. Re-verify T1." ]'
verify FAIL; next T1
check "re-verify FAIL: back to the implementer as a fix round" '[ "$out" = "$FIX" ] && grep -qx "Fix round: 1/2" $W/status.md'
commit_change; verify PASS; next T1
check "verified, an ASK thread and a commit to push: the duo stop" '[[ "$out" == "stop duo "*"1 ASK"*"push"* ]]'
next T1 approve; next T1
check "approved: push and reply" '[ "$out" = "$PUSH" ]'
git push -q origin HEAD; triage_md 1 yes FIX ASK; next T1
check "replied: the round is done, the run ends" '[ "$out" = "end Duo round 1 is answered. Run /fetch-review T1 after the next review." ]'
duo_round 2; next T1
check "round 2: triage again" '[ "$out" = "$TRIAGE" ]'
triage_md 2 no "PUSH BACK"; next T1
check "no ASK, nothing to push: push and reply without a stop" '[ "$out" = "$PUSH" ]'
triage_md 2 no FIX; commit_change; verify FAIL; next T1
check "a fix round in Duo round 2" 'grep -qx "Fix round: 1/2" $W/status.md'
duo_round 3; next T1
check "a new Duo round starts the fix rounds over" '[ "$out" = "$TRIAGE" ] && grep -qx "Fix round: 0/2" $W/status.md'
printf '# Duo review triage: T1\n| d1 | a.txt:1 | FIX | r | |\n' > $W/review-triage.md; next T1
check "review-triage.md without a Round line: a stop no approval passes" '[[ "$out" == "stop duo "*"Round:"* ]] && { next T1 approve; [ $rc -eq 1 ]; }'

# ---------- the agents' templates write the lines next-stage.sh reads ----------
A="$ROOT/payload/.github/agents"
check "planner template: the four Stop flags" 'grep -qx "## Stop flags" $A/planner.agent.md && [ "$(grep -cxE -- "- (Requirement gaps|Migration|Feature flag|Other team): no" $A/planner.agent.md)" -eq 4 ]'
check "verifier template: Commit is the HEAD it checked, PASS or FAIL" 'grep -q "^Commit: <the HEAD you checked" $A/verifier.agent.md && ! grep -q "or none>" $A/verifier.agent.md'
check "evidence template: Commit line" 'grep -q "^Commit: <the HEAD" $A/evidence.agent.md'
check "review-responder: Round and Replied lines in review-triage.md" 'grep -q "Round: <n>" $A/review-responder.agent.md && grep -q "Replied: yes" $A/review-responder.agent.md'

# ---------- the header's contract names every stop the script raises ----------
NS="$ROOT/payload/scripts/agent/next-stage.sh"
# stop_doc: the header's "stop <stop-id> <reason>" entry as one line.
stop_doc() { awk '/^#  +stop <stop-id> <reason>/ { on = 1 } /^#  +end <reason>/ { on = 0 } on' "$NS" | sed 's/^#//' | tr -s ' \n' '  '; }
ids() { grep -oE "_$1 [a-z-]+ " "$NS" | awk '{ print $2 }' | sort -u; }
for id in $(ids stop); do
  check "header: the $id stop is listed" 'stop_doc | sed "s/no approval passes.*//" | grep -qw -- "$id"'
done
for id in $(ids unreadable); do
  check "header: the $id stop is listed as one no approval passes" 'stop_doc | grep -q "no approval passes" && stop_doc | sed "s/.*no approval passes//" | grep -qw -- "$id"'
done
# macOS ships bash 3.2: no associative arrays, mapfile or ${x,,}.
check "runs on bash 3.2: no bash 4 features" '! grep -nE "(declare|local) -A|mapfile|readarray|\$\{[A-Za-z_]+(,,|\^\^)\}" "$NS"'
check "header: end names both ends of a run" 'grep -E "^#  +end <reason>" -A1 "$NS" | grep -q "Duo round"'
check "one parser for the last Key line: _status_value, _plan_flag and _field use _last_value" '[ "$(grep -cF "index(\$0, k) == 1" "$NS")" -eq 1 ] && ( for f in _status_value _plan_flag _field; do sed -n "/^$f() {/,/^}/p" "$NS" | grep -q _last_value || exit 1; done )'
# no_unclear_names: none of _fp, _st (functions) or v, tr (variables: declared, set or read) in the router.
no_unclear_names() {
  ! grep -nE '(^|[^A-Za-z0-9_])(_fp|_st)([^A-Za-z0-9_]|$)' "$NS" &&
  ! grep -nE 'local [^#]*[[:space:]](v|tr)([[:space:]]|$)|(^|[[:space:]])(v|tr)=|\$\{?(v|tr)([^A-Za-z0-9_]|$)' "$NS"
}
check "no unclear names: _fp, _st, v and tr are renamed" 'no_unclear_names > "$T/out.txt"'

# ---------- a task started on v1.2.2 carries on (ADR 0002) ----------
# v1.2.2's own scripts start the task, stop it at requirements and record the
# approval; the current scripts then take over, as after install.sh --update.
if git -C "$ROOT" cat-file -e "v1.2.2^{commit}" 2>/dev/null; then
  mkdir "$T/v122"; git -C "$ROOT" archive v1.2.2 payload/scripts/agent payload/.github/agents | tar -x -C "$T/v122"
  git init -q --bare -b main "$T/carry.git"
  git init -q -b main "$T/carry"; cd "$T/carry"
  git config user.email t@t; git config user.name t; git remote add origin "$T/carry.git"
  mkdir -p scripts .github; cp -r "$T/v122/payload/scripts/agent" scripts/; cp -r "$T/v122/payload/.github/agents" .github/
  printf '.work/\n.agent.env\n' > .gitignore; : > .agent.env
  echo one > a.txt; git add -A; git commit -qm init; git push -q origin main
  $S/start-task.sh T2 carry > "$T/out.txt" 2>&1
  printf '# T2: Export\n## Acceptance criteria\n- AC-1: x\n' > .work/T2/requirements.md
  $S/next-stage.sh T2 > "$T/out.txt" 2>&1; $S/next-stage.sh T2 approve > "$T/out.txt" 2>&1
  check "v1.2.2 approved its requirements stop" 'grep -q "^Approved requirements: " .work/T2/status.md'
  rm -rf scripts/agent .github/agents
  cp -r "$ROOT/payload/scripts/agent" scripts/; cp -r "$ROOT/payload/.github/agents" .github/
  next T2
  check "after the update, the run carries on to the planner" '[ $rc -eq 0 ] && [ "$out" = "run planner AUTO RUN. Plan T2." ]'
  check "a task from v1.2.2 has no run.log; it starts with this decision" '[ "$(wc -l < .work/T2/run.log)" -eq 1 ] && grep -q " run planner " .work/T2/run.log'
  cd "$T/proj"
else
  echo "skip: v1.2.2 carry-on test (v1.2.2 isn't in this clone, e.g. a shallow one)"
fi

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
