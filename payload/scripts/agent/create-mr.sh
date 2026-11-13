#!/usr/bin/env bash
# Usage: create-mr.sh <task-id>
# Pushes the task branch and creates the GitLab MR, or updates its description
# if one is already open. Reads .work/<task-id>/mr.md: the first line is
# "# <title>" and the rest is the description. Saves MR_IID to state.env.
set -euo pipefail
source "$(dirname "$0")/config.sh"
require git glab jq

TASK="${1:?usage: create-mr.sh <task-id>}"
DIR="$(task_dir "$TASK")"
load_state "$TASK"

MR_FILE="$DIR/mr.md"
[ -f "$MR_FILE" ] || { echo "Write $MR_FILE first." >&2; exit 1; }
TITLE="$(head -n1 "$MR_FILE" | sed -E 's/^#[[:space:]]*//')"
DESC="$(tail -n +2 "$MR_FILE")"
BRANCH_ENC="$(jq -rn --arg b "$BRANCH" '$b|@uri')"

find_mr() {
  glab api "projects/:id/merge_requests?source_branch=$BRANCH_ENC&state=opened" \
    | jq -r '.[0] | if . == null then empty else "\(.iid) \(.web_url)" end'
}

git push --quiet -u origin "$BRANCH"

existing="$(find_mr)"
if [ -n "$existing" ]; then
  IID="${existing%% *}"
  glab api -X PUT "projects/:id/merge_requests/$IID" \
    -f "title=$TITLE" -f "description=$DESC" >/dev/null
  action="Updated"
else
  args=(--source-branch "$BRANCH" --target-branch "$BASE_BRANCH"
        --title "$TITLE" --description "$DESC" --remove-source-branch --yes)
  [ "$MR_DRAFT" = "true" ] && args+=(--draft)
  glab mr create "${args[@]}" >/dev/null
  existing="$(find_mr)"
  [ -n "$existing" ] || { echo "MR creation reported success but no open MR was found." >&2; exit 1; }
  IID="${existing%% *}"
  action="Created"
fi

set_state "$TASK" MR_IID "$IID"
echo "$action MR !$IID: ${existing#* }"
