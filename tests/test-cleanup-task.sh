#!/usr/bin/env bash
# Tests cleaning up a finished task (scripts/agent/cleanup-task.sh, #132) in a
# scratch repo with a local bare remote and the shared fake glab: only a merged
# or closed MR is cleaned up, a merged task's branch goes and a closed one's
# stays, parked debt is never lost silently, the remote is never touched, and
# --finished sweeps every task.
# Usage: tests/test-cleanup-task.sh     (exit 0 = all passed)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
check() { if eval "$2"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; sed 's/^/      /' "$T/out.txt" 2>/dev/null; fi; }
S=scripts/agent

# ---------- the shared fake glab: the forge's state in $STUB ----------
export STUB="$T/stub"; mkdir -p "$STUB"
export FAKE_FORGE="$STUB" PATH="$ROOT/tests/lib/fake-glab:$PATH"
echo me > "$STUB/me"
# mr <iid> <state>: the MR as GitLab returns it.
mr() { printf '{"iid":%s,"state":"%s","draft":false,"target_branch":"main","source_branch":"b","title":"t","description":"","web_url":"https://gitlab.test/mr/%s","author":{"username":"me"},"diff_refs":null}\n' "$1" "$2" "$1" > "$STUB/mr-$1.json"; }

# ---------- scratch repo ----------
git init -q --bare -b main "$T/remote.git"
git init -q -b main "$T/proj"; cd "$T/proj"
git config user.email t@t; git config user.name t
git remote add origin "$T/remote.git"
mkdir -p scripts; cp -r "$ROOT/payload/scripts/agent" scripts/
printf '.work/\n.agent.env\n' > .gitignore
echo one > a.txt; git add -A; git commit -qm init; git push -q origin main
: > .agent.env

st() { bash -c 'source scripts/agent/config.sh; "$@"' _ "$@"; }
# task <id> [iid]: a delivery task with a commit on its branch, pushed, back on
# main; with an iid, its MR recorded.
task() {
  $S/start-task.sh "$1" "slug-$1" > /dev/null 2>&1
  echo "$1" > "f-$1.txt"; git add "f-$1.txt"; git commit -qm "$1"; git push -q origin HEAD
  mkdir -p ".work/$1/logs"; echo log > ".work/$1/logs/checks.log"
  git switch -q main
  [ -n "${2:-}" ] && st state_set_mr_iid "$1" "$2"
  return 0
}
branch_of() { st state_branch "$1"; }
has_branch() { git show-ref --verify --quiet "refs/heads/$1"; }
on_remote() { git ls-remote --exit-code --heads origin "$1" > /dev/null 2>&1; }
# review <iid>: an MR review's work folder and worktree, as start-review.sh leaves them.
review() {
  st state_init_review "mr-$1" "$1"; echo '{}' > ".work/mr-$1/mr.json"
  git worktree add -q --detach "$(st review_worktree "mr-$1")" HEAD
}
clean() { $S/cleanup-task.sh "$@" > "$T/out.txt" 2>&1; rc=$?; }
debt() { printf '# Tech debt parked during %s\n\n### CR-5 · major · Maintainability · `a.txt:1`\n- **What:** w\n- **Status:** %s\n' "$1" "$2" > ".work/$1/tech-debt.md"; }

# ---------- arguments ----------
clean
check "no task id: usage, status 1" '[ $rc -eq 1 ] && grep -q "usage: cleanup-task.sh" "$T/out.txt"'
clean ../x
check "a task id with a path in it is refused" '[ $rc -eq 1 ] && grep -q "not a task id" "$T/out.txt"'
clean NOPE
check "an unknown task is refused" '[ $rc -eq 1 ] && grep -q "No task NOPE" "$T/out.txt"'

# ---------- merged: the branch and the work folder go ----------
task T1 1; mr 1 merged; B1="$(branch_of T1)"
clean T1
check "merged: exit 0" '[ $rc -eq 0 ]'
check "merged: the local branch is deleted (squash-merged, so git branch -d would refuse)" '! has_branch "$B1"'
check "merged: the work folder is deleted" '[ ! -e .work/T1 ]'
check "merged: the remote is never touched" 'on_remote "$B1" && ! grep -qv "^api" "$STUB/calls.log"'
check "merged: says what it removed" 'grep -q "$B1" "$T/out.txt" && grep -q ".work/T1" "$T/out.txt"'

# ---------- closed: the work folder goes, the branch stays ----------
task T2 2; mr 2 closed; B2="$(branch_of T2)"
clean T2
check "closed: exit 0, the work folder is deleted" '[ $rc -eq 0 ] && [ ! -e .work/T2 ]'
check "closed: the local branch is kept, with the command to delete it" 'has_branch "$B2" && grep -qF "git branch -D $B2" "$T/out.txt"'
check "closed: notes that the remote branch still exists" 'grep -q "origin/$B2" "$T/out.txt"'

# ---------- refused: nothing changes ----------
task T3 3; mr 3 opened
clean T3
check "an open MR: refused, nothing changes" '[ $rc -eq 1 ] && grep -q "MR !3 is opened" "$T/out.txt" && [ -d .work/T3 ] && has_branch "$(branch_of T3)"'
task T4
clean T4
check "no MR yet: refused, pointing at --force" '[ $rc -eq 1 ] && grep -q "no MR" "$T/out.txt" && grep -q -- "--force" "$T/out.txt" && [ -d .work/T4 ]'
B4="$(branch_of T4)"; clean T4 --force
check "--force on a task with no MR: the work folder goes, the branch stays" '[ $rc -eq 0 ] && [ ! -e .work/T4 ] && has_branch "$B4"'
task T5 55
clean T5
check "the MR's state can't be read: refused, nothing changes" '[ $rc -eq 1 ] && grep -q "Can.t tell whether MR !55" "$T/out.txt" && [ -d .work/T5 ]'
task T6 6; mr 6 merged; git switch -q "$(branch_of T6)"
clean T6
check "on the task's branch: refused, nothing changes" '[ $rc -eq 1 ] && grep -q "switch to another branch" "$T/out.txt" && [ -d .work/T6 ]'
git switch -q main
echo dirty >> a.txt; clean T6
check "uncommitted changes: refused, nothing changes" '[ $rc -eq 1 ] && grep -q "uncommitted changes" "$T/out.txt" && [ -d .work/T6 ] && has_branch "$(branch_of T6)"'
git checkout -q -- a.txt

# ---------- parked debt is never lost silently ----------
task T7 7; mr 7 merged; debt T7 parked
clean T7
check "parked debt: refused, the entries printed" '[ $rc -eq 1 ] && grep -q "CR-5" "$T/out.txt" && grep -q -- "--drop-debt" "$T/out.txt" && [ -d .work/T7 ]'
clean T7 --drop-debt
check "--drop-debt: cleaned up" '[ $rc -eq 0 ] && [ ! -e .work/T7 ]'
task T8 8; mr 8 merged; debt T8 dropped
clean T8
check "debt that isn't parked doesn't stop it" '[ $rc -eq 0 ] && [ ! -e .work/T8 ]'

# ---------- an MR review: the worktree and the work folder go ----------
review 9; mr 9 merged; WT9="$(st review_worktree mr-9)"
clean mr-9
check "MR review, merged: the worktree and the work folder go" '[ $rc -eq 0 ] && [ ! -e "$WT9" ] && [ ! -e .work/mr-9 ] && ! git worktree list | grep -q "mr-9"'
review 10; mr 10 closed; WT10="$(st review_worktree mr-10)"
$S/start-review.sh 10 --done > "$T/out.txt" 2>&1; rc=$?
check "start-review.sh --done does the same" '[ $rc -eq 0 ] && [ ! -e "$WT10" ] && [ ! -e .work/mr-10 ]'
review 11; mr 11 opened
clean mr-11
check "MR review, open: refused" '[ $rc -eq 1 ] && [ -d .work/mr-11 ] && [ -e "$(st review_worktree mr-11)" ]'
clean mr-11 --force
check "MR review, open, --force: cleaned up" '[ $rc -eq 0 ] && [ ! -e .work/mr-11 ] && [ ! -e "$(st review_worktree mr-11)" ]'

# ---------- --finished: every task, skipping what it can't clean ----------
rm -rf .work/T3 .work/T4 .work/T5 .work/T6
task F1 21; mr 21 merged
task F2 22; mr 22 closed
task F3 23; mr 23 opened
task F4 24; mr 24 merged; debt F4 parked
task F5
review 25; mr 25 merged
clean --finished
check "--finished: exit 0" '[ $rc -eq 0 ]'
check "--finished: the merged and closed tasks are cleaned" '[ ! -e .work/F1 ] && [ ! -e .work/F2 ] && [ ! -e .work/mr-25 ]'
check "--finished: the open, no-MR and parked-debt tasks are kept" '[ -d .work/F3 ] && [ -d .work/F4 ] && [ -d .work/F5 ]'
check "--finished: a summary of cleaned, skipped and still open" 'grep -q "^Cleaned: .*F1" "$T/out.txt" && grep -q "^Cleaned: .*mr-25" "$T/out.txt" && grep -q "^Skipped: F4 (parked debt" "$T/out.txt" && grep -q "^Still open: .*F3" "$T/out.txt" && grep -q "^Still open: .*F5" "$T/out.txt"'
clean --finished --force
check "--finished takes no other option" '[ $rc -eq 1 ] && [ -d .work/F5 ]'

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
