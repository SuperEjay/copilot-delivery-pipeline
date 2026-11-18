#!/usr/bin/env bash
# Tests the task state module (scripts/agent/task-state.sh) through its
# interface, in a scratch repo: readers parse .work/<id>/state.env and never run
# it, files from v1.1.0 still read, required keys fail with one message each.
# Usage: tests/test-task-state.sh     (exit 0 = all passed)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
check() {
  if eval "$2"; then pass=$((pass + 1)); else
    fail=$((fail + 1)); echo "FAIL: $1"
    { echo "stdout:"; cat "$T/out.txt"; echo "stderr:"; cat "$T/err.txt"; } 2>/dev/null | sed 's/^/      /'
  fi
}

git init -q -b main "$T/proj"; cd "$T/proj"
mkdir -p scripts; cp -r "$ROOT/payload/scripts/agent" scripts/
W=.work/T1; mkdir -p $W
# st <function> <args...>: call the module the way a script does.
st() { bash -c 'source scripts/agent/config.sh; "$@"' _ "$@" > "$T/out.txt" 2> "$T/err.txt"; }
out() { [ "$(cat "$T/out.txt")" = "$1" ]; }
err() { [ "$(cat "$T/err.txt")" = "$1" ]; }
state() { printf '%s\n' "$@" > $W/state.env; }

# ---------- readers ----------
state TASK=T1 BRANCH=feature/T1-gate REVIEW_ROUND=2 MR_IID=7 REVIEW_IDS=123 REVIEWED_SHA=abc   # a v1.1.0 file
st state_branch T1;       check "reads BRANCH from a v1.1.0 file" '[ $? -eq 0 ] && out feature/T1-gate'
st state_mr_iid T1;       check "reads MR_IID"                    '[ $? -eq 0 ] && out 7'
st state_review_round T1; check "reads REVIEW_ROUND"              '[ $? -eq 0 ] && out 2'
st state_review_ids T1;   check "reads REVIEW_IDS"                '[ $? -eq 0 ] && out 123'
st state_reviewed_sha T1; check "reads REVIEWED_SHA"              '[ $? -eq 0 ] && out abc'

state TASK=T1 BRANCH=feature/T1-gate
st state_review_round T1; check "REVIEW_ROUND defaults to 0"      '[ $? -eq 0 ] && out 0'
st state_review_ids T1;   check "REVIEW_IDS defaults to empty"    '[ $? -eq 0 ] && out ""'
st state_reviewed_sha T1; check "REVIEWED_SHA defaults to empty"  '[ $? -eq 0 ] && out ""'

state BRANCH=feature/T1-old MR_IID=5 BRANCH=feature/T1-new MR_IID=6
st state_branch T1;       check "the last line wins for a repeated key" 'out feature/T1-new'
state BRANCH=b XMR_IID=9 MR_IID_OLD=8 REVIEW_IDS=a=b
st state_mr_iid T1;       check "only an exact key matches" '[ $? -ne 0 ] && out ""'
st state_review_ids T1;   check "a value may contain =" 'out a=b'

# ---------- the file is data, never run ----------
state 'BRANCH=feature/T1-$(touch pwned)' 'MR_IID=`touch pwned2`'
st state_branch T1;       check "a branch with \$(...) is read literally, not run" 'out "feature/T1-\$(touch pwned)" && [ ! -e pwned ]'
st state_mr_iid T1;       check "backticks are read literally, not run" 'out "\`touch pwned2\`" && [ ! -e pwned2 ]'
state BRANCH=b MAX_REVIEW_ROUNDS=99 BASE_BRANCH=release
bash -c 'source scripts/agent/config.sh; state_branch T1 >/dev/null; echo "$MAX_REVIEW_ROUNDS $BASE_BRANCH"' > "$T/out.txt" 2> "$T/err.txt"
check "keys the module doesn't know don't override settings" 'out "3 main"'

# ---------- missing keys and files ----------
state TASK=T1 BRANCH=feature/T1-gate
st state_mr_iid T1
check "no MR_IID: one message, status 1" '[ $? -eq 1 ] && out "" && err "No MR for T1 yet (no MR_IID in .work/T1/state.env). Run scripts/agent/create-mr.sh T1 first."'
state BRANCH=feature/T1-gate MR_IID=
st state_mr_iid T1;       check "an empty MR_IID counts as missing" '[ $? -eq 1 ] && grep -q "^No MR for T1 yet" "$T/err.txt"'
state TASK=T1 MR_IID=7
st state_branch T1
check "no BRANCH: one message, status 1" '[ $? -eq 1 ] && out "" && err "No BRANCH in .work/T1/state.env. start-task.sh writes it, so the file was changed by hand or is damaged."'
for r in state_branch state_mr_iid state_review_round state_review_ids state_reviewed_sha; do
  st $r T9
  check "$r: no state file is an error" '[ $? -eq 1 ] && out "" && err "No .work/T9/state.env. Run scripts/agent/start-task.sh first."'
done

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
