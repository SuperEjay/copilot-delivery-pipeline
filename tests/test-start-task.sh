#!/usr/bin/env bash
# Tests scripts/agent/start-task.sh, including adopting an existing branch or
# your own open MR (#96, ADR 0004), in a scratch repo with a local remote and
# a stub glab ("me" is the glab user).
# Usage: tests/test-start-task.sh     (exit 0 = all passed)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
check() { if eval "$2"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; sed 's/^/      /' "$T/out.txt" 2>/dev/null; fi; }
S=scripts/agent

# ---------- stub glab: the MR from $STUB/mr-<iid>.json ----------
export STUB="$T/stub"; mkdir -p "$STUB"
cat > "$STUB/glab" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "api user") echo '{"username":"me"}' ;;
  "api projects/:id/merge_requests/"*)
    a="$*"; f="$STUB/mr-${a##*/}.json"; [ -f "$f" ] && cat "$f" || { echo "404 Not Found" >&2; exit 1; } ;;
  *) echo "stub glab: unexpected $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$STUB/glab"; export PATH="$STUB:$PATH"
# mr <iid> <branch> [state] [author] [target] [source project]: the stub MR.
mr() {
  jq -n --argjson i "$1" --arg b "$2" --arg s "${3:-opened}" --arg a "${4:-me}" --arg t "${5:-main}" --argjson sp "${6:-1}" \
    '{iid: $i, project_id: 1, source_project_id: $sp, state: $s, author: {username: $a}, source_branch: $b, target_branch: $t,
      title: "My own title", description: "My description.\n\nSecond paragraph."}' > "$STUB/mr-$1.json"
}

# ---------- scratch repo; a second clone pushes branches "someone else" made ----------
git init -q --bare -b main "$T/remote.git"
git init -q -b main "$T/proj"; cd "$T/proj"
git config user.email t@t; git config user.name t
git remote add origin "$T/remote.git"
mkdir -p scripts; cp -r "$ROOT/payload/scripts/agent" scripts/
printf '.work/\n.agent.env\n' > .gitignore
echo one > a.txt; git add -A; git commit -qm init; git push -q origin main
git clone -q "$T/remote.git" "$T/other"; git -C "$T/other" config user.email o@o; git -C "$T/other" config user.name o
# remote_branch <name> [commits]: a branch on origin, off main, with commits.
remote_branch() {
  git -C "$T/other" fetch -q origin; git -C "$T/other" switch -q -C "$1" origin/main
  for (( i = 0; i < ${2:-1}; i++ )); do echo "$1 $i" >> "$T/other/b.txt"; git -C "$T/other" add -A; git -C "$T/other" commit -qm "$1 $i"; done
  git -C "$T/other" push -q -f origin "$1"
}
start() { $S/start-task.sh "$@" > "$T/out.txt" 2>&1; rc=$?; }
st() { bash -c 'source scripts/agent/config.sh; "$@"' _ "$@"; }
home() { git switch -q main; }

# ---------- the usual start is unchanged ----------
start T0 usual
check "a normal start: <prefix>/<task>-<slug> from origin/main, not adopted" '[ $rc -eq 0 ] && [ "$(git branch --show-current)" = "$(st state_branch T0)" ] && [ -z "$(st state_adopted T0)" ]'
start T0 usual
check "the same start again: fine" '[ $rc -eq 0 ]'
home
start T0 other-slug
check "the same task on a different branch: refused, naming its branch" '[ $rc -ne 0 ] && grep -q "$(st state_branch T0)" "$T/out.txt" && [ "$(git branch --show-current)" = main ]'

# ---------- --branch: only on origin ----------
remote_branch feat/mine 2
echo two >> a.txt; git commit -qam "main moves on"; git push -q origin main
start T1 --branch feat/mine
check "--branch on origin only: checked out, tracking origin" '[ $rc -eq 0 ] && [ "$(git branch --show-current)" = feat/mine ] && [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/feat/mine)" ] && [ "$(git rev-parse --abbrev-ref @{u})" = origin/feat/mine ]'
check "the state: that branch, ADOPTED=branch, no MR" '[ "$(st state_branch T1)" = feat/mine ] && [ "$(st state_adopted T1)" = branch ] && ! grep -q "^MR_IID=" .work/T1/state.env'
check "adopted-commits.md lists the branch's own commits and files, not main's" 'grep -q "feat/mine 1" .work/T1/adopted-commits.md && grep -q "b.txt" .work/T1/adopted-commits.md && ! grep -q "main moves on" .work/T1/adopted-commits.md'
check "it says how far behind origin/main it is, and changes nothing about it" 'grep -q "1 commit(s) behind origin/main" "$T/out.txt" && [ "$(git rev-list --count HEAD..origin/main)" -eq 1 ]'
start T1 --branch feat/mine
check "adopting the same branch again: fine" '[ $rc -eq 0 ]'
home
start T1 --branch feat/else
check "the same task, another branch: refused" '[ $rc -ne 0 ] && grep -q feat/mine "$T/out.txt"'
start T1 usual
check "the adopted task with a slug: refused" '[ $rc -ne 0 ] && grep -q feat/mine "$T/out.txt"'

# ---------- --branch: local behind origin, diverged, local only, missing ----------
remote_branch feat/behind 2; git fetch -q origin
git branch -q feat/behind "origin/feat/behind~1"   # your copy is one commit behind
start T2 --branch feat/behind
check "local behind origin: fast-forwarded" '[ $rc -eq 0 ] && [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/feat/behind)" ]'
home

remote_branch feat/split 1; git fetch -q origin
git switch -q -c feat/split origin/feat/split; echo mine > c.txt; git add c.txt; git commit -qm "local only commit"; home
git -C "$T/other" switch -q feat/split; echo theirs >> "$T/other/b.txt"; git -C "$T/other" commit -qam theirs; git -C "$T/other" push -q origin feat/split
start T3 --branch feat/split
check "local and origin diverged: refused, no state" '[ $rc -ne 0 ] && grep -qi diverged "$T/out.txt" && [ ! -f .work/T3/state.env ] && [ "$(git branch --show-current)" = main ]'

git branch -q feat/local main
start T4 --branch feat/local
check "a branch only you have: adopted" '[ $rc -eq 0 ] && [ "$(git branch --show-current)" = feat/local ] && [ "$(st state_adopted T4)" = branch ]'
home
start T5 --branch feat/nowhere
check "a branch that exists nowhere: refused, no state" '[ $rc -ne 0 ] && [ ! -f .work/T5/state.env ]'

start T15 --branch main
check "--branch BASE_BRANCH: refused, the pipeline never works on the base branch" '[ $rc -ne 0 ] && grep -q "base branch" "$T/out.txt" && [ ! -f .work/T15/state.env ] && [ "$(git branch --show-current)" = main ]'

# git ls-remote fails (network, auth): an error, not "the branch isn't on origin"
mkdir -p "$T/gitfail"; REAL_GIT="$(command -v git)"
printf '#!/usr/bin/env bash\n[ "$1" = ls-remote ] && { echo "fatal: could not read from remote" >&2; exit 128; }\nexec "%s" "$@"\n' "$REAL_GIT" > "$T/gitfail/git"; chmod +x "$T/gitfail/git"
PATH="$T/gitfail:$PATH" $S/start-task.sh T16 --branch feat/local > "$T/out.txt" 2>&1; rc=$?
check "origin can't be asked about the branch: refused, says so, no state" '[ $rc -ne 0 ] && grep -qi "origin" "$T/out.txt" && [ ! -f .work/T16/state.env ] && [ "$(git branch --show-current)" = main ]'

echo dirty >> a.txt
start T6 --branch feat/mine
check "uncommitted changes: refused" '[ $rc -ne 0 ] && grep -q "uncommitted changes" "$T/out.txt" && [ ! -f .work/T6/state.env ]'
git checkout -q a.txt

# ---------- --mr: your own open MR ----------
remote_branch feat/mr7 1; mr 7 feat/mr7
start T7 --mr 7
check "--mr: its source branch is checked out, ADOPTED=mr" '[ $rc -eq 0 ] && [ "$(git branch --show-current)" = feat/mr7 ] && [ "$(st state_adopted T7)" = mr ] && [ "$(st state_branch T7)" = feat/mr7 ]'
check "--mr: no MR_IID yet, so the full route runs before ship" '! grep -q "^MR_IID=" .work/T7/state.env'
check "--mr: your title and description are kept in adopted-mr.md" '[ "$(head -n1 .work/T7/adopted-mr.md)" = "# My own title" ] && grep -q "^Second paragraph.$" .work/T7/adopted-mr.md'
home

remote_branch feat/mr8 1; mr 8 feat/mr8 opened ann
start T8 --mr 8
check "--mr on a teammate's MR: refused, pointing at /review-mr" '[ $rc -ne 0 ] && grep -q "/review-mr 8" "$T/out.txt" && [ ! -f .work/T8/state.env ] && [ "$(git branch --show-current)" = main ]'
mr 9 feat/mr7 merged
start T9 --mr 9
check "--mr on a merged MR: refused" '[ $rc -ne 0 ] && grep -q merged "$T/out.txt" && [ ! -f .work/T9/state.env ]'
mr 10 feat/mr7 opened me release
start T10 --mr 10
check "--mr targeting another branch than BASE_BRANCH: refused" '[ $rc -ne 0 ] && grep -q release "$T/out.txt" && [ ! -f .work/T10/state.env ]'
mr 11 feat/mr7 opened me main 2
start T11 --mr 11
check "--mr from a fork: refused" '[ $rc -ne 0 ] && grep -qi fork "$T/out.txt" && [ ! -f .work/T11/state.env ]'
start T12 --mr 404
check "--mr that doesn't exist: refused" '[ $rc -ne 0 ] && [ ! -f .work/T12/state.env ]'
start T13 --mr abc
check "--mr with a non-number: refused" '[ $rc -ne 0 ] && grep -q "number" "$T/out.txt"'
start T14 --mr
check "--mr without an iid: usage" '[ $rc -ne 0 ] && grep -q "usage" "$T/out.txt"'

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
