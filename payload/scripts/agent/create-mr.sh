#!/usr/bin/env bash
# Usage: create-mr.sh <task-id>
# Pushes the task branch and creates the GitLab MR, or updates its description
# if one is already open. Reads .work/<task-id>/mr.md: the first line is
# "# <title>" and the rest is the description. Saves MR_IID to state.env.
# Refuses unless the ship gate allows it (scripts/agent/ship-gate.sh): updating
# an MR is a push; a new MR also needs evidence approved at that same commit.
set -euo pipefail
source "$(dirname "$0")/config.sh"
source "$(dirname "$0")/ship-gate.sh"
source "$(dirname "$0")/forge-lib.sh"
require git glab jq

TASK="${1:?usage: create-mr.sh <task-id>}"
DIR="$(task_dir "$TASK")"
BRANCH="$(state_branch "$TASK")" || exit 1

MR_FILE="$DIR/mr.md"
[ -f "$MR_FILE" ] || { echo "Write $MR_FILE first." >&2; exit 1; }
TITLE="$(head -n1 "$MR_FILE" | sed -E 's/^#[[:space:]]*//')"
DESC="$(tail -n +2 "$MR_FILE")"

gate_require "$TASK" push
existing="$(forge_mr_for_branch "$BRANCH")" || { echo "Can't ask GitLab for $BRANCH's open MR (see above)." >&2; exit 1; }
[ -n "$existing" ] || gate_require "$TASK" new-mr

git push --quiet -u origin "$BRANCH"
if [ -n "$existing" ]; then
  IID="${existing%% *}"
  forge_mr_update "$IID" "$TITLE" "$DESC" || { echo "Pushed, but couldn't update MR !$IID (see above)." >&2; exit 1; }
  action="Updated"
else
  draft=""; [ "$MR_DRAFT" = "true" ] && draft=--draft
  existing="$(forge_mr_create "$BRANCH" "$BASE_BRANCH" "$TITLE" "$DESC" $draft)" || { echo "Pushed, but couldn't create the MR (see above)." >&2; exit 1; }
  IID="${existing%% *}"
  action="Created"
fi

state_set_mr_iid "$TASK" "$IID"
echo "$action MR !$IID: ${existing#* }"
# Assign it to you when nobody is (#150). A missing assignee never fails the ship.
forge_mr_assign_me "$IID" || echo "Warning: couldn't assign MR !$IID to you (see above). Assign it in GitLab." >&2
