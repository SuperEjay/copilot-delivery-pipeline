#!/usr/bin/env bash
# Usage: set-review-spec.sh <mr-iid> <clickup-task-id>
# Stores the ClickUp task an MR review is checked against, as given by the user
# at the spec stop (ADR 0003). The requirements agent runs it, then fetches the
# task. It changes nothing else: the review worktree stays at the head under
# review.
set -euo pipefail
source "$(dirname "$0")/config.sh"

IID="${1:?usage: set-review-spec.sh <mr-iid> <clickup-task-id>}"
ID="${2:?usage: set-review-spec.sh <mr-iid> <clickup-task-id>}"
TASK="mr-$IID"
case "$ID" in
  *[!A-Za-z0-9_-]*) echo "Not a ClickUp id: '$ID'. Use the task id alone, such as 86abc123 or a custom id like ENG-42." >&2; exit 1 ;;
esac
[ -f "$(task_dir "$TASK")/state.env" ] || { echo "No MR review of !$IID yet. Run /review-mr $IID first." >&2; exit 1; }
KIND="$(state_kind "$TASK")"
[ "$KIND" = MR_REVIEW ] || { echo "$TASK isn't an MR review (its kind is $KIND)." >&2; exit 1; }
state_set_clickup_id "$TASK" "$ID"
echo "MR review of !$IID: spec is ClickUp task $ID."
