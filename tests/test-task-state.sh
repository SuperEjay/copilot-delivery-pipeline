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
  check "$r: no task state is an error" '[ $? -eq 1 ] && out "" && err "No .work/T9/state.env. Run scripts/agent/start-task.sh first."'
done

# ---------- writers ----------
W2=.work/T2
st state_init T2 feature/T2-x
check "state_init writes the v1.1.0 format" '[ $? -eq 0 ] && [ "$(cat $W2/state.env)" = "$(printf "TASK=T2\nBRANCH=feature/T2-x\nREVIEW_ROUND=0")" ]'
st state_init T2 feature/T2-other
check "state_init leaves an existing file alone" '[ $? -eq 0 ] && grep -qx BRANCH=feature/T2-x $W2/state.env && ! grep -q other $W2/state.env'
st state_set_mr_iid T2 7; st state_set_mr_iid T2 8; st state_mr_iid T2
check "state_set_mr_iid replaces the value, one line per key" 'out 8 && [ "$(grep -c "^MR_IID=" $W2/state.env)" -eq 1 ]'
st state_set_review T2 1 999; st state_review_round T2
check "state_set_review writes the round" 'out 1'
st state_review_ids T2;       check "state_set_review writes the thread ids" 'out 999'
st state_set_reviewed_sha T2 abc123; st state_reviewed_sha T2
check "state_set_reviewed_sha writes the commit" 'out abc123'
st state_branch T2;           check "setters keep the other keys" 'out feature/T2-x'
check "no temp file is left behind" '[ ! -e $W2/state.env.tmp ]'
st state_set_reviewed_sha T2 '$(touch pwned3)'; st state_reviewed_sha T2
check "a written \$(...) reads back as text" 'out "\$(touch pwned3)" && [ ! -e pwned3 ]'

cp $W2/state.env "$T/before"
st state_set_mr_iid T2 $'9\nBASE_BRANCH=x'
check "a value with a newline is refused" '[ $? -eq 1 ] && err "Not writing MR_IID to .work/T2/state.env: the value contains a newline." && cmp -s $W2/state.env "$T/before"'
st state_set_review T2 2 $'1\n2'
check "state_set_review writes neither key when one has a newline" '[ $? -eq 1 ] && grep -q "Not writing REVIEW_IDS" "$T/err.txt" && cmp -s $W2/state.env "$T/before"'
st state_init T3 $'feature/T3\nMR_IID=1'
check "state_init refuses a branch with a newline" '[ $? -eq 1 ] && [ ! -e .work/T3/state.env ]'
for w in "state_set_mr_iid T9 1" "state_set_review T9 1 2" "state_set_reviewed_sha T9 abc"; do
  st $w
  check "${w%% *}: no task state is an error" '[ $? -eq 1 ] && err "No .work/T9/state.env. Run scripts/agent/start-task.sh first." && [ ! -e .work/T9/state.env ]'
done

# ---------- task kind: delivery or MR review (ADR 0003) ----------
state TASK=T1 BRANCH=feature/T1-gate REVIEW_ROUND=0   # a delivery file, written before kinds existed
st state_kind T1;         check "no KIND reads as a delivery task" '[ $? -eq 0 ] && out DELIVERY'
st state_kind T9;         check "state_kind: no task state is an error" '[ $? -eq 1 ] && err "No .work/T9/state.env. Run scripts/agent/start-task.sh first."'

st state_init_review mr-7 7
check "state_init_review writes the kind and the MR, no branch, no Duo round" '[ $? -eq 0 ] && [ "$(cat .work/mr-7/state.env)" = "$(printf "TASK=mr-7\nKIND=MR_REVIEW\nMR_IID=7")" ]'
st state_kind mr-7;       check "reads KIND=MR_REVIEW"        '[ $? -eq 0 ] && out MR_REVIEW'
st state_mr_iid mr-7;     check "an MR review reads its MR"   '[ $? -eq 0 ] && out 7'
st state_branch mr-7
check "an MR review has no branch: one message, status 1" '[ $? -eq 1 ] && out "" && err "mr-7 is an MR review: it has no branch."'
st state_init_review mr-7 8
check "state_init_review leaves an existing file alone" '[ $? -eq 0 ] && grep -qx MR_IID=7 .work/mr-7/state.env'
st state_init_review mr-8 $'8\nKIND=x'
check "state_init_review refuses an iid with a newline" '[ $? -eq 1 ] && [ ! -e .work/mr-8/state.env ]'

st state_clickup_id mr-7; check "CLICKUP_ID defaults to empty" '[ $? -eq 0 ] && out ""'
st state_set_clickup_id mr-7 86abc; st state_set_clickup_id mr-7 86def; st state_clickup_id mr-7
check "state_set_clickup_id replaces the value, one line per key" 'out 86def && [ "$(grep -c "^CLICKUP_ID=" .work/mr-7/state.env)" -eq 1 ]'
st state_kind mr-7;       check "setting the ClickUp id keeps the kind" 'out MR_REVIEW'
st state_set_clickup_id mr-7 $'1\nKIND=DELIVERY'
check "state_set_clickup_id refuses a newline" '[ $? -eq 1 ] && grep -q "Not writing CLICKUP_ID" "$T/err.txt" && grep -qx CLICKUP_ID=86def .work/mr-7/state.env'
st state_set_clickup_id T9 1
check "state_set_clickup_id: no task state is an error" '[ $? -eq 1 ] && [ ! -e .work/T9/state.env ]'

# ---------- load_state and set_state are gone (ADR 0002) ----------
# A script you changed (which --update keeps) that still calls them must stop
# at the call with a message saying what to use, never run on with empty
# values: under set -e, and without it, as review-signals.sh, run-checks.sh,
# next-stage.sh and capture-evidence.sh run.
REMOVED="was removed in v2.0.0. Use the state_* functions in scripts/agent/task-state.sh (see CHANGELOG.md, v2.0.0)."
state TASK=T1 BRANCH=feature/T1-gate MR_IID=7
for opts in "set -eu" "set -u" ":"; do
  bash -c "$opts"'; source scripts/agent/config.sh; load_state T1; echo "reached ${BRANCH-unset}"' > "$T/out.txt" 2> "$T/err.txt"
  check "load_state is gone (${opts/#:/no set}): the script stops at the call and says what to use" '[ $? -eq 1 ] && out "" && err "load_state $REMOVED"'
done
cp $W/state.env "$T/before"
for opts in "set -eu" ":"; do
  bash -c "$opts"'; source scripts/agent/config.sh; set_state T1 MR_IID 9; echo reached' > "$T/out.txt" 2> "$T/err.txt"
  check "set_state is gone (${opts/#:/no set}): the script stops, state.env unchanged" '[ $? -eq 1 ] && out "" && err "set_state $REMOVED" && cmp -s $W/state.env "$T/before"'
done

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
