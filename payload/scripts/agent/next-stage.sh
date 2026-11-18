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
