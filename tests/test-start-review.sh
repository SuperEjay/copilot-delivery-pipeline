#!/usr/bin/env bash
# Tests the start of an MR review (scripts/agent/start-review.sh, ADR 0003) in
# a scratch repo with a local bare remote and a stub glab: which MRs it accepts,
# the review worktree at the MR's head (fork MRs too, through
# refs/merge-requests/<iid>/head), and that the user's own checkout is never
# touched.
# Usage: tests/test-start-review.sh     (exit 0 = all passed)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
check() { if eval "$2"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; sed 's/^/      /' "$T/out.txt" 2>/dev/null; fi; }
S=scripts/agent

# ---------- stub glab: the MR's state comes from $STUB/mr-<iid>.json ----------
export STUB="$T/stub"; mkdir -p "$STUB"
cat > "$STUB/glab" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "api projects/:id/merge_requests/"*)
    f="$STUB/mr-${2##*/}.json"
    if [ -f "$f" ]; then cat "$f"; else echo '{"message":"404 Not found"}'; echo "glab: 404 Not Found" >&2; exit 1; fi ;;
  *) echo "stub glab: unexpected $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$STUB/glab"; export PATH="$STUB:$PATH"
mr() { printf '{"iid":%s,"state":"%s","draft":%s,"target_branch":"%s"}\n' "$1" "$2" "${3:-false}" "${4:-main}" > "$STUB/mr-$1.json"; }

# ---------- scratch repo: the MR's commits live only under refs/merge-requests/ ----------
git init -q --bare -b main "$T/remote.git"
git init -q -b main "$T/proj"; cd "$T/proj"
git config user.email t@t; git config user.name t
git remote add origin "$T/remote.git"
mkdir -p scripts; cp -r "$ROOT/payload/scripts/agent" scripts/
printf '.work/\n.agent.env\n' > .gitignore
echo one > a.txt; git add -A; git commit -qm init; git push -q origin main
# mr_push <iid> <text>: a commit on top of main, published only as the MR's head
# (as GitLab does for a fork MR); prints nothing, leaves the checkout on main.
mr_push() {
  git -C "$T/proj" worktree add -q --detach "$T/fork" "${3:-main}" 2>/dev/null
  echo "$2" > "$T/fork/a.txt"; git -C "$T/fork" commit -qam "$2"
  git -C "$T/fork" push -q origin "HEAD:refs/merge-requests/$1/head" --force
  git -C "$T/fork" rev-parse HEAD > "$T/head-$1"
  git -C "$T/proj" worktree remove --force "$T/fork"
}
st() { bash -c 'source scripts/agent/config.sh; "$@"' _ "$@" 2>&1; }
WT="$(git rev-parse --absolute-git-dir)/pipeline-reviews"
review() { $S/start-review.sh "$@" > "$T/out.txt" 2>&1; rc=$?; }

mr_push 7 seven

# ---------- refused: merged, closed, unknown, bad arguments ----------
mr 7 merged; review 7
check "a merged MR is refused, nothing created" '[ $rc -eq 1 ] && grep -q "MR !7 is merged" "$T/out.txt" && [ ! -e .work/mr-7 ] && [ ! -e "$WT/mr-7" ]'
mr 7 closed; review 7
check "a closed MR is refused, nothing created" '[ $rc -eq 1 ] && grep -q "MR !7 is closed" "$T/out.txt" && [ ! -e .work/mr-7 ] && [ ! -e "$WT/mr-7" ]'
review 99
check "an MR glab can't find is refused, with glab's message" '[ $rc -eq 1 ] && grep -q "Could not read MR !99" "$T/out.txt" && grep -q "404" "$T/out.txt" && [ ! -e .work/mr-99 ]'
review
check "no iid: usage, status 1" '[ $rc -ne 0 ] && grep -q "usage: start-review.sh <mr-iid> \[clickup-task-id\]" "$T/out.txt"'
review '!7'
check "an iid that isn't a number is refused" '[ $rc -eq 1 ] && grep -q "MR iid must be a number" "$T/out.txt" && [ ! -e ".work/mr-!7" ]'

# ---------- a draft, with a dirty checkout on the user's own branch ----------
git switch -q -c feature/mine
echo mine > a.txt; echo new > untracked.txt                # uncommitted work
mr 7 opened true; review 7 86abc
check "a draft MR is accepted" '[ $rc -eq 0 ]'
check "the review worktree is at the MR head (a fork MR, fetched by its ref)" '[ "$(git -C "$WT/mr-7" rev-parse HEAD)" = "$(cat "$T/head-7")" ]'
check "git knows the worktree" 'git worktree list | grep -q "pipeline-reviews/mr-7"'
check "a dirty checkout doesn't block it, and is left as it was" '[ "$(cat a.txt)" = mine ] && [ -f untracked.txt ]'
check "the user stays on their branch at their commit" '[ "$(git branch --show-current)" = feature/mine ] && [ "$(git rev-parse HEAD)" = "$(git rev-parse main)" ]'
check "the task state is an MR review of !7" '[ "$(st state_kind mr-7)" = MR_REVIEW ] && [ "$(st state_mr_iid mr-7)" = 7 ]'
check "the MR's target branch is stored and fetched" '[ "$(st state_target_branch mr-7)" = main ] && git rev-parse -q --verify refs/remotes/origin/main >/dev/null'
check "the ClickUp id passed at the start is stored" '[ "$(st state_clickup_id mr-7)" = 86abc ]'
check "it says where the worktree and work folder are" 'grep -q "$WT/mr-7" "$T/out.txt" && grep -q "Work folder: .work/mr-7" "$T/out.txt"'

# ---------- a second run: the author pushed again ----------
mr_push 7 seven-again "$(cat "$T/head-7")"
review 7
check "a second run moves the worktree to the new head" '[ $rc -eq 0 ] && [ "$(git -C "$WT/mr-7" rev-parse HEAD)" = "$(cat "$T/head-7")" ]'
check "a second run without an id keeps the stored one" '[ "$(st state_clickup_id mr-7)" = 86abc ]'
check "a second run leaves the user's checkout alone" '[ "$(git branch --show-current)" = feature/mine ] && [ "$(cat a.txt)" = mine ]'
review 7 86xyz
check "an id passed on a later run replaces the stored one" '[ $rc -eq 0 ] && [ "$(st state_clickup_id mr-7)" = 86xyz ]'
check "the worktree is still the only one for !7" '[ "$(git worktree list | grep -c "pipeline-reviews/mr-7")" -eq 1 ]'

# ---------- a worktree folder removed by hand ----------
rm -rf "$WT/mr-7"
review 7
check "a worktree deleted by hand is made again" '[ $rc -eq 0 ] && [ "$(git -C "$WT/mr-7" rev-parse HEAD)" = "$(cat "$T/head-7")" ]'
rm -rf "$WT/mr-7"; mkdir -p "$WT/mr-7"
review 7
check "an empty folder left in its place is made a worktree again" '[ $rc -eq 0 ] && [ -f "$WT/mr-7/.git" ] && [ "$(git -C "$WT/mr-7" rev-parse HEAD)" = "$(cat "$T/head-7")" ]'

# ---------- set-review-spec.sh: the ClickUp id given at the spec stop ----------
spec() { $S/set-review-spec.sh "$@" > "$T/out.txt" 2>&1; rc=$?; }
spec 7 86new
check "set-review-spec.sh stores the id" '[ $rc -eq 0 ] && [ "$(st state_clickup_id mr-7)" = 86new ]'
check "set-review-spec.sh leaves the worktree where it was" '[ "$(git -C "$WT/mr-7" rev-parse HEAD)" = "$(cat "$T/head-7")" ]'
spec 7 'CU-86 x'
check "set-review-spec.sh refuses an id with spaces" '[ $rc -eq 1 ] && grep -q "ClickUp id" "$T/out.txt" && [ "$(st state_clickup_id mr-7)" = 86new ]'
spec 8 86abc
check "set-review-spec.sh needs a started review" '[ $rc -eq 1 ] && grep -q "/review-mr 8" "$T/out.txt" && [ ! -e .work/mr-8 ]'

# ---------- a delivery task is not an MR review ----------
git stash -q -u; git switch -q main
printf 'LINT_CMD=\nTYPECHECK_CMD=\nUNIT_CMD=\nINTEGRATION_CMD=\nE2E_CMD=\n' > .agent.env
$S/start-task.sh T1 gate > "$T/out.txt" 2>&1
check "a task started with start-task.sh still reads as delivery" '[ "$(st state_kind T1)" = DELIVERY ]'
mkdir -p .work/mr-5; cp .work/T1/state.env .work/mr-5/state.env
spec 5 86abc
check "set-review-spec.sh refuses a delivery task" '[ $rc -eq 1 ] && grep -q "isn.t an MR review" "$T/out.txt" && ! grep -q CLICKUP_ID .work/mr-5/state.env'

# ---------- dependencies in the review worktree (#80) ----------
# The user's checkout has installed dependencies for its lockfile. INSTALL_CMD
# is a stub that records where it ran and how often.
git switch -q main   # start-task.sh switched to T1's branch
echo '{"lock":1}' > package-lock.json; git add package-lock.json; git commit -qm lock; git push -q origin main
mkdir -p node_modules/dep; echo main > node_modules/dep/index.js
cat > .agent.env <<'EOF'
LINT_CMD='pwd > "$STUB/lint-dir"; [ -f node_modules/dep/index.js ]'
TYPECHECK_CMD=
UNIT_CMD='false'
INTEGRATION_CMD=
E2E_CMD=
INSTALL_CMD='pwd >> "$STUB/installs"; mkdir -p node_modules/dep && echo fresh > node_modules/dep/index.js'
EOF
: > "$STUB/installs"
mr_push 11 eleven main
mr 11 opened; review 11
check "same lockfile: node_modules is linked from the main checkout, no install" '[ $rc -eq 0 ] && [ -L "$WT/mr-11/node_modules" ] && [ "$(cat "$WT/mr-11/node_modules/dep/index.js")" = main ] && [ ! -s "$STUB/installs" ]'
check "it says the dependencies are linked" 'grep -q "Dependencies: linked" "$T/out.txt"'

# the author changes the lockfile
git -C "$T/proj" worktree add -q --detach "$T/fork" "$(cat "$T/head-11")"
echo '{"lock":2}' > "$T/fork/package-lock.json"; git -C "$T/fork" commit -qam "bump dep"
git -C "$T/fork" push -q origin "HEAD:refs/merge-requests/11/head" --force; git -C "$T/proj" worktree remove --force "$T/fork"
review 11
check "a changed lockfile: INSTALL_CMD runs in the worktree, the link is replaced" '[ $rc -eq 0 ] && [ "$(cat "$STUB/installs")" = "$WT/mr-11" ] && [ ! -L "$WT/mr-11/node_modules" ] && [ "$(cat "$WT/mr-11/node_modules/dep/index.js")" = fresh ]'
check "the main checkout's node_modules is untouched" '[ ! -L node_modules ] && [ "$(cat node_modules/dep/index.js)" = main ]'
check "the install log is kept" 'grep -q "Dependencies: installed" "$T/out.txt" && [ -f .work/mr-11/logs/install.log ]'
review 11
check "the same lockfile again: no second install" '[ $rc -eq 0 ] && [ "$(wc -l < "$STUB/installs")" -eq 1 ]'
sed -i "s|^INSTALL_CMD=.*|INSTALL_CMD='echo npm ERR boom; exit 3'|" .agent.env
echo '{"lock":3}' > "$T/lock3"
git -C "$T/proj" worktree add -q --detach "$T/fork" "$(git -C "$WT/mr-11" rev-parse HEAD)"
cp "$T/lock3" "$T/fork/package-lock.json"; git -C "$T/fork" commit -qam "bump again"
git -C "$T/fork" push -q origin "HEAD:refs/merge-requests/11/head" --force; git -C "$T/proj" worktree remove --force "$T/fork"
review 11
check "a failed install stops the review, pointing at its log" '[ $rc -eq 1 ] && grep -q "INSTALL_CMD failed" "$T/out.txt" && grep -q ".work/mr-11/logs/install.log" "$T/out.txt"'

# ---------- run-checks.sh in an MR review: the worktree, no verified commit ----------
sed -i "s|^INSTALL_CMD=.*|INSTALL_CMD='true'|" .agent.env
$S/run-checks.sh mr-11 all > "$T/out.txt" 2>&1; rc=$?
check "run-checks.sh runs an MR review's checks in its worktree" '[ "$(cat "$STUB/lint-dir")" = "$WT/mr-11" ] && grep -q "^PASS  lint" "$T/out.txt"'
check "a failing check still fails the run" '[ $rc -eq 1 ] && grep -q "^FAIL  unit" "$T/out.txt"'
sed -i "s|^UNIT_CMD=.*|UNIT_CMD=true|" .agent.env
$S/run-checks.sh mr-11 all > "$T/out.txt" 2>&1; rc=$?
check "a passing full run records no verified commit in an MR review" '[ $rc -eq 0 ] && [ ! -e .work/mr-11/verified-head ] && ! grep -q "^VERIFIED" "$T/out.txt"'
check "it says which commit it checked" 'grep -q "^CHECKED $(git -C "$WT/mr-11" rev-parse HEAD)" "$T/out.txt"'
$S/run-checks.sh T1 lint > "$T/out.txt" 2>&1
check "a delivery task's checks still run in the main checkout" '[ "$(cat "$STUB/lint-dir")" = "$PWD" ]'

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
