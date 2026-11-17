#!/usr/bin/env bash
# Tests the push gates in a scratch repo with a local bare remote and a stub
# glab: only the verified commit can be pushed, a new MR needs evidence
# approved at that commit, and re-fetching the same Duo review isn't a new round.
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
  "api --paginate"*discussions*) cat "$STUB/discussions.json" ;;
  "api projects/:id/merge_requests?"*) if [ -f "$STUB/mr" ]; then echo '[{"iid":7,"web_url":"https://gitlab.test/mr/7"}]'; else echo '[]'; fi ;;
  "mr create"*) touch "$STUB/mr" ;;
  "api -X PUT"*) : ;;
  *) echo "stub glab: unexpected $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$STUB/glab"; export PATH="$STUB:$PATH"
threads() { jq -n --args '[$ARGS.positional[] | {id: ., notes: [{resolvable: true, resolved: false, author: {username: "duo"}, body: "fix it", position: {new_path: "a.txt", new_line: 1}}]}]' "$@" > "$STUB/discussions.json"; }

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

# ---------- push-branch only pushes the verified commit ----------
echo two >> a.txt; git commit -qam "slice 1"
$S/push-branch.sh T1 > "$T/out.txt" 2>&1
check "push refused without verification" '[ $? -ne 0 ] && ! git ls-remote --exit-code origin feature/T1-gate >/dev/null'
$S/run-checks.sh T1 all > /dev/null 2>&1
echo three >> a.txt; git commit -qam "unverified"
$S/push-branch.sh T1 > "$T/out.txt" 2>&1
check "push refused with commits after verification" '[ $? -ne 0 ] && grep -q "1 commit(s) since" "$T/out.txt"'
$S/run-checks.sh T1 all > /dev/null 2>&1
$S/push-branch.sh T1 > "$T/out.txt" 2>&1
check "verified commit pushes" '[ $? -eq 0 ] && [ "$(git ls-remote origin feature/T1-gate | cut -f1)" = "$(git rev-parse HEAD)" ]'

# ---------- create-mr needs evidence approved at the same commit ----------
printf '# feat: gate [T1]\n\nbody\n' > $W/mr.md
mkdir -p $W/evidence; printf -- '- [x] AC-1 · `AC-1.md` · works\n' > $W/evidence/evidence.md; echo ok > $W/evidence/AC-1.md
approve_at() {  # what approve-evidence.sh writes, at a given commit
  { echo "# approved 2026-01-01T00:00:00Z by t at commit $1"
    echo "$(sha256sum $W/evidence/evidence.md | cut -d' ' -f1)  evidence.md"
    echo "$(sha256sum $W/evidence/AC-1.md | cut -d' ' -f1)  AC-1.md"; } > $W/evidence/APPROVED; }
$S/create-mr.sh T1 > "$T/out.txt" 2>&1
check "new MR refused without evidence approval" '[ $? -ne 0 ] && [ ! -f "$STUB/mr" ]'
approve_at "$(git rev-parse HEAD~1)"
$S/create-mr.sh T1 > "$T/out.txt" 2>&1
check "new MR refused when evidence is from an older commit" '[ $? -ne 0 ] && grep -q "approved at commit" "$T/out.txt" && [ ! -f "$STUB/mr" ]'
approve_at "$(git rev-parse --short HEAD)"
$S/upload-evidence.sh T1 --check > "$T/out.txt" 2>&1
check "short-sha approvals (v1.1.0 format) still match" '[ $? -eq 0 ]'
approve_at "$(git rev-parse HEAD)"
$S/create-mr.sh T1 > "$T/out.txt" 2>&1
check "MR created at the verified, approved commit" '[ $? -eq 0 ] && [ -f "$STUB/mr" ] && grep -q "^MR_IID=7$" $W/state.env'
echo four >> a.txt; git commit -qam "duo fix"
$S/create-mr.sh T1 > "$T/out.txt" 2>&1
check "MR update refused before re-verification" '[ $? -ne 0 ]'
$S/run-checks.sh T1 all > /dev/null 2>&1
$S/create-mr.sh T1 > "$T/out.txt" 2>&1
check "MR update allowed once re-verified (no new evidence needed)" '[ $? -eq 0 ] && grep -q "^Updated" "$T/out.txt"'

# ---------- Duo review rounds ----------
threads d1 d2
$S/fetch-duo-review.sh T1 > "$T/out.txt" 2>&1
check "first fetch is round 1" 'grep -q "^Round 1: 2 " "$T/out.txt"'
$S/fetch-duo-review.sh T1 > "$T/out.txt" 2>&1
check "same threads again stay round 1" 'grep -q "^Round 1: 2 .*not a new round" "$T/out.txt" && grep -q "^REVIEW_ROUND=1$" $W/state.env'
threads d2 d3
$S/fetch-duo-review.sh T1 > "$T/out.txt" 2>&1
check "new threads are round 2" 'grep -q "^Round 2: 2 " "$T/out.txt"'
threads d4
$S/fetch-duo-review.sh T1 > "$T/out.txt" 2>&1
check "round 3 refused at MAX_REVIEW_ROUNDS=2" '[ $? -eq 3 ] && jq -e "map(.id) == [\"d2\",\"d3\"]" $W/review.json >/dev/null'
$S/fetch-duo-review.sh T1 --force > "$T/out.txt" 2>&1
check "--force goes past the limit" 'grep -q "^Round 3: 1 " "$T/out.txt"'

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
