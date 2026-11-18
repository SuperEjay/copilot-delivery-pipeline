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
  _end "not built yet"
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
    echo "Pending stop: $pending"
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

PLAN_ACCEPTED=""; AUTO_PLAN=""
decide

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
