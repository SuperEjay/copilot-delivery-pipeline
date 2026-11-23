#!/usr/bin/env bash
# Tests the push gates in a scratch repo with a local bare remote and a stub
# glab: the ship gate's rules (called directly), that push-branch, create-mr and
# upload-evidence go through it, re-fetching the same Duo review isn't a new round,
# and the scripts treat state.env as data.
# Usage: tests/test-gates.sh     (exit 0 = all passed)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
check() { if eval "$2"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; cat "$T/out.txt" 2>/dev/null | sed 's/^/      /'; fi; }
S=scripts/agent

# ---------- stub glab ----------
export STUB="$T/stub"; mkdir -p "$STUB"
cat > "$STUB/glab" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "api user") [ -f "$STUB/no-user" ] && { echo "401 Unauthorized" >&2; exit 1; }; echo '{"username":"me"}' ;;
  "api --paginate"*discussions*) cat "$STUB/discussions.json" ;;
  "api projects/:id/merge_requests?"*) if [ -f "$STUB/mr" ]; then echo '[{"iid":7,"web_url":"https://gitlab.test/mr/7"}]'; else echo '[]'; fi ;;
  "mr create"*) touch "$STUB/mr" ;;
  "api -X PUT"*) : ;;
  *) echo "stub glab: unexpected $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$STUB/glab"; export PATH="$STUB:$PATH"
# discs <id>:<author>[,<author>...]: one thread per argument, its notes by those
# authors in order (each note with its own id). "me" is the glab user.
discs() { jq -n --args '[$ARGS.positional[] | split(":") as [$id, $who] | {id: $id, notes: [$who | split(",") | to_entries[] | {id: "\($id)-n\(.key)", resolvable: true, resolved: false, author: {username: .value}, body: "note by \(.value)", position: {new_path: "a.txt", new_line: 1, head_sha: "sha-\($id)"}}]}]' "$@" > "$STUB/discussions.json"; }
threads() { jq -n --args '[$ARGS.positional[] | {id: ., notes: [{resolvable: true, resolved: false, author: {username: "duo"}, body: "fix it", position: {new_path: "a.txt", new_line: 1, head_sha: "sha-\(.)"}}]}]' "$@" > "$STUB/discussions.json"; }

# ---------- scratch repo ----------
git init -q --bare -b main "$T/remote.git"
git init -q -b main "$T/proj"; cd "$T/proj"
git config user.email t@t; git config user.name t
git remote add origin "$T/remote.git"
mkdir -p scripts; cp -r "$ROOT/payload/scripts/agent" scripts/
printf '.work/\n.agent.env\n' > .gitignore
echo one > a.txt; git add -A; git commit -qm init; git push -q origin main
env_with() { printf 'LINT_CMD=true\nTYPECHECK_CMD=true\nUNIT_CMD=%s\nINTEGRATION_CMD=\nE2E_CMD=\nDUO_USERNAMES=duo\nMAX_REVIEW_ROUNDS=2\n' "$1" > .agent.env; }
env_with true
$S/start-task.sh T1 gate > "$T/out.txt" 2>&1
W=.work/T1

# ---------- run-checks records the verified commit ----------
$S/run-checks.sh T1 fast > "$T/out.txt" 2>&1
check "fast run records nothing" '[ ! -f $W/verified-head ]'
$S/run-checks.sh T1 all > "$T/out.txt" 2>&1
check "full passing run records HEAD" '[ "$(cat $W/verified-head)" = "$(git rev-parse HEAD)" ] && grep -q "^VERIFIED" "$T/out.txt"'
echo dirty >> a.txt
$S/run-checks.sh T1 all > "$T/out.txt" 2>&1
check "dirty tree is not recorded" '[ ! -f $W/verified-head ] && grep -q "uncommitted" "$T/out.txt"'
git checkout -q -- a.txt
$S/run-checks.sh T1 lint types unit integration e2e > "$T/out.txt" 2>&1
check "listing every check counts as full" '[ -f $W/verified-head ]'
env_with false
$S/run-checks.sh T1 all > "$T/out.txt" 2>&1
check "failing full run clears it" '[ ! -f $W/verified-head ]'
env_with true

# ---------- ship gate: the rules, called directly ----------
gate() { bash -c 'source scripts/agent/config.sh; source scripts/agent/ship-gate.sh; gate_require "$@"' _ "$@" > "$T/out.txt" 2>&1; }
approve() { bash -c 'source scripts/agent/config.sh; source scripts/agent/evidence-lib.sh; approval_write T1 AC-1.md' > /dev/null; }
mkdir -p $W/evidence; printf -- '- [x] AC-1 · `AC-1.md` · works\n' > $W/evidence/evidence.md; echo ok > $W/evidence/AC-1.md

echo two >> a.txt; git commit -qam "slice 1"
gate T1 push
check "gate: push refused without a verified commit" '[ $? -ne 0 ] && grep -q "No verified commit" "$T/out.txt"'
$S/run-checks.sh T1 all > /dev/null 2>&1
gate T1 push
check "gate: verified commit may be pushed" '[ $? -eq 0 ]'
echo three >> a.txt; git commit -qam "unverified"
gate T1 push
check "gate: push refused with commits after verification" '[ $? -ne 0 ] && grep -q "1 commit(s) since" "$T/out.txt"'
$S/run-checks.sh T1 all > /dev/null 2>&1
git switch -q -c other
gate T1 push
check "gate: push refused on another branch" '[ $? -ne 0 ] && grep -q "expected feature/T1-gate" "$T/out.txt"'
git switch -q feature/T1-gate
gate T1 new-mr
check "gate: new MR refused without evidence approval" '[ $? -ne 0 ] && grep -q "not approved" "$T/out.txt"'
approve
echo four >> a.txt; git commit -qam "after approval"; $S/run-checks.sh T1 all > /dev/null 2>&1
gate T1 new-mr
check "gate: new MR refused when evidence is from an older commit" '[ $? -ne 0 ] && grep -q "approved at commit" "$T/out.txt"'
approve
gate T1 new-mr
check "gate: new MR allowed with evidence approved at the verified commit" '[ $? -eq 0 ]'
echo changed > $W/evidence/AC-1.md
gate T1 new-mr
check "gate: new MR refused when an approved file changed" '[ $? -ne 0 ] && grep -q "changed after approval" "$T/out.txt"'
echo ok > $W/evidence/AC-1.md
{ echo "# approved 2026-01-01T00:00:00Z by t at commit $(git rev-parse --short HEAD)"   # the v1.1.0 format
  echo "$(sha256sum $W/evidence/evidence.md | cut -d' ' -f1)  evidence.md"
  echo "$(sha256sum $W/evidence/AC-1.md | cut -d' ' -f1)  AC-1.md"; } > $W/evidence/APPROVED
gate T1 new-mr
check "gate: short-sha approvals (v1.1.0 format) still match" '[ $? -eq 0 ]'
gate T1 deploy
check "gate: unknown action is refused" '[ $? -eq 2 ]'

# ---------- the scripts go through the gate ----------
echo five >> a.txt; git commit -qam "slice 2"
$S/push-branch.sh T1 > "$T/out.txt" 2>&1
check "push-branch refuses an unverified commit" '[ $? -ne 0 ] && ! git ls-remote --exit-code origin feature/T1-gate >/dev/null'
$S/run-checks.sh T1 all > /dev/null 2>&1
$S/push-branch.sh T1 > "$T/out.txt" 2>&1
check "push-branch pushes the verified commit" '[ $? -eq 0 ] && [ "$(git ls-remote origin feature/T1-gate | cut -f1)" = "$(git rev-parse HEAD)" ]'
printf '# feat: gate [T1]\n\nbody\n' > $W/mr.md
rm -f $W/evidence/APPROVED
$S/create-mr.sh T1 > "$T/out.txt" 2>&1
check "create-mr refuses a new MR without evidence approval" '[ $? -ne 0 ] && [ ! -f "$STUB/mr" ]'
approve
$S/upload-evidence.sh T1 --check > "$T/out.txt" 2>&1
check "upload-evidence --check accepts the approval" '[ $? -eq 0 ] && grep -q "valid: 1 file" "$T/out.txt"'
$S/create-mr.sh T1 > "$T/out.txt" 2>&1
check "MR created at the verified, approved commit" '[ $? -eq 0 ] && [ -f "$STUB/mr" ] && grep -q "^MR_IID=7$" $W/state.env'
echo six >> a.txt; git commit -qam "duo fix"
$S/create-mr.sh T1 > "$T/out.txt" 2>&1
check "MR update refused before re-verification" '[ $? -ne 0 ]'
$S/run-checks.sh T1 all > /dev/null 2>&1
$S/create-mr.sh T1 > "$T/out.txt" 2>&1
check "MR update allowed once re-verified (no new evidence needed)" '[ $? -eq 0 ] && grep -q "^Updated" "$T/out.txt"'

# ---------- Duo review rounds ----------
threads d1 d2
$S/fetch-duo-review.sh T1 > "$T/out.txt" 2>&1
check "first fetch is round 1" 'grep -q "^Round 1: 2 " "$T/out.txt"'
check "review.json keeps new_line and the commit each thread was made on (head_sha)" 'jq -e "map([.new_line, .head_sha]) == [[1,\"sha-d1\"],[1,\"sha-d2\"]]" $W/review.json >/dev/null'
$S/fetch-duo-review.sh T1 > "$T/out.txt" 2>&1
check "same threads again stay round 1" 'grep -q "^Round 1: 2 .*not a new round" "$T/out.txt" && grep -q "^REVIEW_ROUND=1$" $W/state.env'
threads d2 d3
$S/fetch-duo-review.sh T1 > "$T/out.txt" 2>&1
check "new threads are round 2" 'grep -q "^Round 2: 2 " "$T/out.txt"'
threads d4
echo MAX_REVIEW_ROUNDS=99 >> $W/state.env   # state.env is data: it can't lift the limit
$S/fetch-duo-review.sh T1 > "$T/out.txt" 2>&1
check "round 3 refused at MAX_REVIEW_ROUNDS=2, even with MAX_REVIEW_ROUNDS=99 in state.env" '[ $? -eq 3 ] && jq -e "map(.id) == [\"d2\",\"d3\"]" $W/review.json >/dev/null'
$S/fetch-duo-review.sh T1 --force > "$T/out.txt" 2>&1
check "--force goes past the limit" 'grep -q "^Round 3: 1 " "$T/out.txt"'

# ---------- threads you already answered (#98) ----------
discs d4:duo,me
$S/fetch-duo-review.sh T1 > "$T/out.txt" 2>&1
check "your reply is the last note: skipped, nothing new, no round (even at the limit)" '[ $? -eq 0 ] && grep -q "^1 thread(s) already answered by you, skipped" "$T/out.txt" && grep -q "^Nothing new since round 3" "$T/out.txt" && grep -q "^REVIEW_ROUND=3$" $W/state.env && jq -e ". == []" $W/review.json >/dev/null'
sed -i 's/^DUO_USERNAMES=.*/DUO_USERNAMES=/' .agent.env
discs d4:duo,me d5:me
$S/fetch-duo-review.sh T1 > "$T/out.txt" 2>&1
check "a thread you started yourself counts as answered" '[ $? -eq 0 ] && grep -q "^2 thread(s) already answered by you, skipped" "$T/out.txt" && grep -q "^REVIEW_ROUND=3$" $W/state.env'
env_with true
discs d4:duo,me,duo
$S/fetch-duo-review.sh T1 > "$T/out.txt" 2>&1
check "Duo wrote after your reply: the thread is back, a new round (refused at the limit)" '[ $? -eq 3 ] && grep -q "^REVIEW_ROUND=3$" $W/state.env'
$S/fetch-duo-review.sh T1 --force > "$T/out.txt" 2>&1
check "... and with --force it is round 4" '[ $? -eq 0 ] && grep -q "^Round 4: 1 " "$T/out.txt" && jq -e "map(.id) == [\"d4\"]" $W/review.json >/dev/null'
discs d4:duo,me,duo d6:duo,me
$S/fetch-duo-review.sh T1 > "$T/out.txt" 2>&1
check "an unanswered thread with no new note, plus an answered one: same round, nothing new" '[ $? -eq 0 ] && grep -q "^Round 4: 1 .*not a new round" "$T/out.txt" && grep -q "^Nothing new since round 4" "$T/out.txt" && grep -q "^1 thread(s) already answered" "$T/out.txt" && grep -q "^REVIEW_ROUND=4$" $W/state.env'
touch "$STUB/no-user"
$S/fetch-duo-review.sh T1 > "$T/out.txt" 2>&1; rc=$?
check "the glab user can't be looked up: the fetch fails (not a round-limit exit), the round is untouched" '[ $rc -ne 0 ] && [ $rc -ne 3 ] && grep -qi "glab user" "$T/out.txt" && grep -q "^REVIEW_ROUND=4$" $W/state.env'
rm -f "$STUB/no-user"
# ---------- an MR review's threads: every author, no round (ADR 0003) ----------
# Discussions from Duo, a person, a resolved one, a system note and a plain
# (unresolvable) comment.
jq -n '[
  {id: "t1", notes: [{resolvable: true, resolved: false, author: {username: "duo"}, body: "duo says", position: {new_path: "a.txt", new_line: 1}},
                     {author: {username: "ann"}, body: "agreed"}]},
  {id: "t2", notes: [{resolvable: true, resolved: false, author: {username: "ann"}, body: "ann asks"}]},
  {id: "t3", notes: [{resolvable: true, resolved: true, author: {username: "bob"}, body: "done"}]},
  {id: "t4", notes: [{system: true, resolvable: false, author: {username: "ann"}, body: "added 1 commit"}]},
  {id: "t5", notes: [{resolvable: false, author: {username: "bob"}, body: "looks fine overall"}]}
]' > "$STUB/discussions.json"
bash -c 'source scripts/agent/config.sh; state_init_review mr-7 7'
cp $W/state.env "$T/delivery-state"
$S/fetch-duo-review.sh mr-7 > "$T/out.txt" 2>&1
check "MR review: every author's open threads go to threads.json, Duo's too" '[ $? -eq 0 ] && jq -e "map(.id) == [\"t1\",\"t2\",\"t5\"]" .work/mr-7/threads.json >/dev/null'
check "MR review: DUO_USERNAMES doesn't filter them" 'jq -e "map(.author) | index(\"ann\")" .work/mr-7/threads.json >/dev/null'
check "MR review: replies and the position are kept" 'jq -e ".[0].replies[0].author == \"ann\" and .[0].file == \"a.txt\" and .[0].line == 1" .work/mr-7/threads.json >/dev/null'
check "MR review: no review round counted, no review.json" '! grep -q "^REVIEW_" .work/mr-7/state.env && [ ! -e .work/mr-7/review.json ]'
check "MR review: it says how many and where, with no round" 'grep -q "^3 open thread(s) from every author in .work/mr-7/threads.json" "$T/out.txt" && ! grep -q "Round" "$T/out.txt"'
$S/fetch-duo-review.sh mr-7 > "$T/out.txt" 2>&1
check "MR review: fetching again still counts nothing" '[ $? -eq 0 ] && ! grep -q "^REVIEW_" .work/mr-7/state.env'
check "MR review: the delivery task's round is untouched" 'cmp -s $W/state.env "$T/delivery-state"'

$S/review-signals.sh T1 --mark-reviewed > "$T/out.txt" 2>&1
check "review-signals --mark-reviewed records HEAD" '[ $? -eq 0 ] && grep -qx "REVIEWED_SHA=$(git rev-parse HEAD)" $W/state.env'

# ---------- task state is data, never run ----------
$S/start-task.sh T2 'x$(touch${IFS}pwned)' > "$T/out.txt" 2>&1
$S/push-branch.sh T2 > "$T/out.txt" 2>&1
check "a branch name with \$(...) isn't run by the scripts" '[ ! -e pwned ] && grep -q "No verified commit for T2" "$T/out.txt"'
$S/fetch-duo-review.sh T2 > "$T/out.txt" 2>&1
check "no MR yet: the shared message" '[ $? -eq 1 ] && grep -qx "No MR for T2 yet (no MR_IID in .work/T2/state.env). Run scripts/agent/create-mr.sh T2 first." "$T/out.txt"'

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
