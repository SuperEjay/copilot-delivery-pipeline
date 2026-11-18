#!/usr/bin/env bash
# The auto run's router: decides the next stage, or a stop, from the files in
# .work/<task-id>/. The orchestrator follows it without its own judgement.
#
#   next-stage.sh <task-id>           print one line:
#       run <agent> <prompt>          run that stage agent as a subagent with
#                                     this prompt (it starts with "AUTO RUN.")
#       stop <stop-id> <reason>       wait for the user's decision
#       end <reason>                  the run is over (MR open, waiting on Duo)
#
# Exit 0 for any decision; 1 with the reason on stderr when it can't decide
# (no task state yet: run /start-task first).
set -uo pipefail
source "$(dirname "$0")/config.sh"

TASK="${1:?usage: next-stage.sh <task-id> [approve]}"
CMD="${2:-}"
case "$CMD" in ""|approve) ;; *) echo "usage: next-stage.sh <task-id> [approve]" >&2; exit 1 ;; esac

state_branch "$TASK" > /dev/null 2>&1 || {
  echo "No task state for $TASK. Run /start-task $TASK <slug> first." >&2
  exit 1
}

DIR="$(task_dir "$TASK")"
STATUS="$DIR/status.md"
REL="${DIR#"$REPO_ROOT"/}"

# ---------- status.md: Key: value lines, parsed, never sourced ----------
# _st <Key>: the value of the last "Key: value" line, or empty.
_st() {
  [ -f "$STATUS" ] || return 0
  awk -v k="$1: " 'index($0, k) == 1 { v = substr($0, length(k) + 1) } END { print v }' "$STATUS"
}

# _fp <file|@HEAD>...: one checksum over these inputs (a missing file counts too).
_fp() {
  local f
  for f in "$@"; do
    echo "== $f"
    if [ "$f" = @HEAD ]; then git rev-parse HEAD
    elif [ -f "$DIR/$f" ]; then cat "$DIR/$f"
    else echo "(none)"; fi
  done | sha256sum | cut -c1-16
}

# _approved <stop-id> <fp>: the user approved this stop at this fingerprint.
_approved() { [ -n "$2" ] && [ "$(_st "Approved $1")" = "$2" ]; }

# ---------- the decision ----------
# decide sets VERB (run|stop|end), WHAT (agent or stop id), TEXT (prompt or
# reason), STAGE, and for a stop STOP_FP: the fingerprint an approval is tied to.
_run()  { VERB=run;  WHAT="$1"; TEXT="AUTO RUN. $2"; }
_stop() { VERB=stop; WHAT="$1"; STOP_FP="$2"; TEXT="$3"; }
_end()  { VERB=end;  WHAT=""; TEXT="$1"; }
# _fix_run <key> <prompt>: back to the implementer for a fix. The key (the
# commit it fixes) makes a round count once, however often this is asked.
_fix_run() { FIX_KEY="$1"; _run implementer "$2"; }
# _unreadable <stop-id> <reason>: a stop no approval can pass; the file needs fixing.
_unreadable() { VERB=stop; WHAT="$1"; STOP_FP=""; TEXT="$2"; }

# _plan_flag <name>: yes or no from "- <name>: yes|no" under "## Stop flags".
_plan_flag() {
  awk -v k="- $1:" '/^## / { on = ($0 == "## Stop flags") } on && index($0, k) == 1 { v = tolower(substr($0, length(k) + 1)) }
                    END { gsub(/[ \t]/, "", v); print v }' "$DIR/plan.md"
}

# check_plan <requirements fp>: decide whether the plan may go on (sets PLAN_ACCEPTED
# and AUTO_PLAN), or set a run/stop. Returns 1 when it set a decision.
check_plan() {
  local rfp="$1" pfp acc name v n reasons=() sfp
  pfp="$(_fp plan.md)"; acc="$(_st "Plan accepted")"
  if [ -n "$acc" ] && [ "${acc% *}" = "$pfp" ] && [ "${acc#* }" != "$rfp" ]; then
    _run planner "Requirements for $TASK changed; update plan.md."; return 1
  fi
  [ "$acc" = "$pfp $rfp" ] && return 0

  for name in "Requirement gaps" "Migration" "Feature flag" "Other team"; do
    v="$(_plan_flag "$name")"
    case "$v" in
      yes) reasons+=("$name") ;;
      no) ;;
      *) _unreadable plan "$REL/plan.md has no readable '- $name: yes|no' line under '## Stop flags'. The planner must write it."; return 1 ;;
    esac
  done
  n="$(grep -cE '^- \[[ xX]\] S[0-9]+:' "$DIR/plan.md")"
  [ "$n" -gt 6 ] && reasons+=("$n slices (more than 6)")

  if [ "${#reasons[@]}" -gt 0 ]; then
    sfp="$(_fp plan.md requirements.md)"
    if ! _approved plan "$sfp"; then
      local IFS=,; _stop plan "$sfp" "Review $REL/plan.md: it flags ${reasons[*]}."; return 1
    fi
  else
    AUTO_PLAN="$n"
  fi
  PLAN_ACCEPTED="$pfp $rfp"
}

decide() {
  STAGE=requirements
  if [ ! -f "$DIR/requirements.md" ]; then _run requirements "Analyse $TASK."; return; fi
  local fp; fp="$(_fp requirements.md)"
  if ! _approved requirements "$fp"; then
    _stop requirements "$fp" "Review $REL/requirements.md: answer its open questions here, or approve it."; return
  fi

  STAGE=plan
  if [ ! -f "$DIR/plan.md" ]; then _run planner "Plan $TASK."; return; fi
  check_plan "$fp" || return

  STAGE=build
  if grep -qE '^- \[ \] [SR][0-9]+:' "$DIR/plan.md"; then
    _run implementer "Build $TASK: implement the next unchecked slice in plan.md."; return
  fi

  STAGE=verify
  check_verified || return
  _end "not built yet"
}

# _field <file> <Key>: the value after the last "Key:" line, first word only.
_field() {
  [ -f "$DIR/$1" ] || return 0
  awk -v k="$2:" 'index($0, k) == 1 { split(substr($0, length(k) + 1), w, " "); v = w[1] } END { print v }' "$DIR/$1"
}

# check_verified: HEAD is verified (verification.md PASS at HEAD, and HEAD is
# the verified commit), or set a run/stop and return 1.
check_verified() {
  local head vc vr
  head="$(git rev-parse HEAD)"
  if [ -f "$DIR/verification.md" ]; then
    vc="$(_field verification.md Commit)"; vr="$(_field verification.md Result)"
    if [ -z "$vc" ]; then
      _unreadable verify "$REL/verification.md has no 'Commit:' line. The verifier must write the HEAD it checked."; return 1
    fi
    if [ "$vc" = "$head" ]; then
      case "$vr" in
        FAIL) _fix_run "verify:$head" "Fix the verification failures for $TASK (see verification.md)."; return 1 ;;
        PASS) [ "$(cat "$DIR/verified-head" 2>/dev/null)" = "$head" ] && return 0 ;;
        *) _unreadable verify "$REL/verification.md has no 'Result: PASS|FAIL' line."; return 1 ;;
      esac
    fi
  fi
  _run verifier "Verify $TASK."; return 1
}

# apply_fix_round: count a new fix round, or turn it into the fix-limit stop.
apply_fix_round() {
  local round key
  round="$(_st "Fix round")"; round="${round%%/*}"; round="${round:-0}"; key="$(_st "Fix key")"
  NEW_ROUND="$round"; NEW_KEY="$key"
  [ "$VERB" = run ] && [ -n "$FIX_KEY" ] && [ "$FIX_KEY" != "$key" ] || return 0
  if [ "$round" -ge "$MAX_AUTO_FIX_ROUNDS" ]; then
    _stop fix-limit "$FIX_KEY" "$MAX_AUTO_FIX_ROUNDS fix rounds used (MAX_AUTO_FIX_ROUNDS) and the work still needs fixing: $TEXT Approve to allow more rounds, or tell me how to go on."
    return 0
  fi
  NEW_ROUND=$(( round + 1 )); NEW_KEY="$FIX_KEY"
}

# check_stall: the same run as last time, with none of its inputs changed,
# means the stage ran and changed nothing: stop instead of looping. Approving
# that stop lets the stage run once more.
INPUTS=(@HEAD requirements.md plan.md verification.md code-review.md evidence/evidence.md
        evidence/APPROVED mr.md review-triage.md state.env verified-head)
check_stall() {
  [ "$VERB" = run ] || return 0
  INPUTS_FP="$(_fp "${INPUTS[@]}")"
  LAST_RUN="run $WHAT $TEXT"; LAST_RUN_FP="$INPUTS_FP"
  [ "$LAST_RUN" = "$(_st "Last run")" ] && [ "$INPUTS_FP" = "$(_st "Last run inputs")" ] || return 0
  if _approved stalled "$INPUTS_FP"; then unset 'APPROVED[stalled]'; return 0; fi
  _stop stalled "$INPUTS_FP" "$WHAT ran but changed nothing in $REL or the code. Approve to run it once more, or tell me how to go on. It would get: $TEXT"
}

# ---------- auto-decisions.md ----------
_auto_decision() {
  local f="$DIR/auto-decisions.md"
  [ -f "$f" ] || printf '# Auto-decisions: %s\nDecisions the pipeline made for you in an auto run. Review them before shipping.\n' "$TASK" > "$f"
  printf '\n## %s\n- **When:** %s\n- **What:** %s\n- **Why:** %s\n- **Rule:** %s\n' \
    "$1" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$2" "$3" "$4" >> "$f"
}
record_auto_plan() {
  _auto_decision "Plan accepted without a stop" \
    "plan.md ($1 slices) went on to the implementer." \
    "none of its Stop flags is \"yes\", and it has 6 or fewer slices." \
    "Plan: stop only on requirement gaps, a migration, a feature flag, another team's work, or more than 6 slices (ADR 0001)."
}

# ---------- status.md writer ----------
write_status() {
  local pending=""
  [ "$VERB" = stop ] && pending="$WHAT $STOP_FP"
  mkdir -p "$DIR"
  {
    echo "# Auto run status: $TASK"
    echo "Written by scripts/agent/next-stage.sh. Don't edit it."
    echo
    echo "Stage: $STAGE"
    echo "Last decision: $LINE"
    echo "Last run: ${LAST_RUN:-$(_st "Last run")}"
    echo "Last run inputs: ${LAST_RUN_FP:-$(_st "Last run inputs")}"
    echo "Pending stop: $pending"
    echo "Fix round: $NEW_ROUND/$MAX_AUTO_FIX_ROUNDS"
    echo "Fix key: $NEW_KEY"
    echo "Plan accepted: ${PLAN_ACCEPTED:-$(_st "Plan accepted")}"
    for id in "${!APPROVED[@]}"; do echo "Approved $id: ${APPROVED[$id]}"; done
  } > "$STATUS.tmp"
  mv "$STATUS.tmp" "$STATUS"
}

# Approvals: one fingerprint per stop id.
declare -A APPROVED=()
if [ -f "$STATUS" ]; then
  while IFS= read -r l; do
    id="${l#Approved }"; id="${id%%: *}"; APPROVED[$id]="${l#*: }"
  done < <(grep '^Approved [a-z-]*: ' "$STATUS")
fi

PLAN_ACCEPTED=""; AUTO_PLAN=""; FIX_KEY=""; LAST_RUN=""; LAST_RUN_FP=""
decide
apply_fix_round
check_stall

if [ "$CMD" = approve ]; then
  pending="$(_st "Pending stop")"
  if [ -z "$pending" ]; then echo "No stop is waiting for an approval." >&2; exit 1; fi
  if [ "$VERB" = stop ] && [ -z "$STOP_FP" ]; then
    echo "This stop can't be approved: $TEXT" >&2; exit 1
  fi
  if [ "$VERB" != stop ] || [ "$pending" != "$WHAT $STOP_FP" ]; then
    echo "The stop changed since it was shown. Run next-stage.sh $TASK again and show the user the new stop." >&2
    exit 1
  fi
  APPROVED[$WHAT]="$STOP_FP"
  NEW_ROUND=0   # the user looked at the run: fix rounds start over
  LINE="$(_st "Last decision")"
  write_status
  echo "Approved the $WHAT stop."
  exit 0
fi

case "$VERB" in
  run)  LINE="run $WHAT $TEXT" ;;
  stop) LINE="stop $WHAT $TEXT" ;;
  end)  LINE="end $TEXT" ;;
esac
write_status
[ -n "$AUTO_PLAN" ] && record_auto_plan "$AUTO_PLAN"
echo "$LINE"
