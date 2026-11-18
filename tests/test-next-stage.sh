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
printf 'MAX_AUTO_FIX_ROUNDS=2\n' > .agent.env
W=.work/T1

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

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
