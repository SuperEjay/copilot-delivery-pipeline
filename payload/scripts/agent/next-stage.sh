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

# ---------- the decision ----------
# decide sets VERB (run|stop|end), WHAT (agent or stop id), TEXT (prompt or
# reason), STAGE, and for a stop STOP_FP: the fingerprint an approval is tied to.
_run()  { VERB=run;  WHAT="$1"; TEXT="AUTO RUN. $2"; }
_stop() { VERB=stop; WHAT="$1"; STOP_FP="$2"; TEXT="$3"; }
_end()  { VERB=end;  WHAT=""; TEXT="$1"; }

decide() {
  STAGE=requirements
  if [ ! -f "$DIR/requirements.md" ]; then _run requirements "Analyse $TASK."; return; fi
  _stop requirements "$(_fp requirements.md)" \
    "Review $REL/requirements.md: answer its open questions here, or approve it."
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
  } > "$STATUS.tmp"
  mv "$STATUS.tmp" "$STATUS"
}

decide
case "$VERB" in
  run)  LINE="run $WHAT $TEXT" ;;
  stop) LINE="stop $WHAT $TEXT" ;;
  end)  LINE="end $TEXT" ;;
esac
write_status
echo "$LINE"
