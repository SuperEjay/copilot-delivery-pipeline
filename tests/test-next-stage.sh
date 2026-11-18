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
mkdir -p scripts; cp -r "$ROOT/payload/scripts/agent" scripts/
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

# next <args>: run next-stage.sh, output in $T/out.txt and $out, exit code in $rc.
next() { $S/next-stage.sh "$@" > "$T/out.txt" 2>&1; rc=$?; out="$(cat "$T/out.txt")"; }

# ---------- no task state ----------
next T1
check "no task state: exit 1, pointing at /start-task" '[ $rc -eq 1 ] && grep -q "/start-task" "$T/out.txt"'

$S/start-task.sh T1 router > "$T/out.txt" 2>&1

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
printf '# Plan: T1\n## Slices\n- [ ] S1: one\n' > $W/plan.md
next T1
check "plan.md without Stop flags: stop plan, naming the missing line" '[[ "$out" == "stop plan "*"Stop flags"* ]]'
next T1 approve
check "an unreadable plan can't be approved" '[ $rc -eq 1 ]'
plan_md 3 no yes
next T1
check "a migration flag stops the plan" '[[ "$out" == "stop plan "*"Migration"* ]]'
check "no auto-decision for a plan that stops" '[ ! -f $W/auto-decisions.md ]'
plan_md 7
next T1
check "7 slices stop the plan" '[[ "$out" == "stop plan "*"7 slices"* ]]'
next T1 approve; next T1
check "an approved plan goes on" '[[ "$out" != stop* ]] && [ ! -f $W/auto-decisions.md ]'
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
plan_md 4
next T1
check "updated plan: accepted again" '[ "$out" = "$BUILD" ] && [ "$(grep -c "Plan accepted without a stop" $W/auto-decisions.md)" -eq 2 ]'

# ---------- slices ----------
sed -i 's/^- \[ \] S1:/- [x] S1:/; s/^- \[ \] S2:/- [x] S2:/; s/^- \[ \] S3:/- [x] S3:/' $W/plan.md
next T1
check "one slice left: still the implementer" '[ "$out" = "$BUILD" ]'
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
check "asking again doesn't count the round twice" '[ "$out" = "$FIX" ] && grep -qx "Fix round: 1/2" $W/status.md'
commit_change; next T1
check "HEAD moved since the FAIL: verify again" '[ "$out" = "$VERIFY" ]'
verify FAIL; next T1
check "second FAIL: fix round 2" '[ "$out" = "$FIX" ] && grep -qx "Fix round: 2/2" $W/status.md'
commit_change; verify FAIL; next T1
check "third FAIL: stop at MAX_AUTO_FIX_ROUNDS (default 2)" '[[ "$out" == "stop fix-limit "*"2 fix rounds"* ]]'
next T1 approve; next T1
check "approving the fix-limit stop allows another round" '[ "$out" = "$FIX" ] && grep -qx "Fix round: 1/2" $W/status.md'
printf '# Verification: T1\nResult: FAIL\n' > $W/verification.md
next T1
check "verification.md without a Commit line: a stop no approval passes" '[[ "$out" == "stop verify "*"Commit:"* ]] && { next T1 approve; [ $rc -eq 1 ]; }'
commit_change; verify PASS; rm $W/verified-head; next T1
check "PASS without the verified commit recorded: verify again" '[ "$out" = "$VERIFY" ]'
verify PASS; next T1
check "PASS at the verified commit: past the verifier" '[ "$out" != "$VERIFY" ] && [ "$out" != "$FIX" ]'

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
