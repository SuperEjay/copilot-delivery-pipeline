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

decide() {
  STAGE=requirements
  if [ ! -f "$DIR/requirements.md" ]; then _run requirements "Analyse $TASK."; return; fi
  local fp; fp="$(_fp requirements.md)"
  if ! _approved requirements "$fp"; then
    _stop requirements "$fp" "Review $REL/requirements.md: answer its open questions here, or approve it."; return
  fi

  STAGE=plan
  if [ ! -f "$DIR/plan.md" ]; then _run planner "Plan $TASK."; return; fi
  _end "not built yet"
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

decide

if [ "$CMD" = approve ]; then
  pending="$(_st "Pending stop")"
  if [ -z "$pending" ]; then echo "No stop is waiting for an approval." >&2; exit 1; fi
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
echo "$LINE"
