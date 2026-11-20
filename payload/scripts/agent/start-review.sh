#!/usr/bin/env bash
# Usage: start-review.sh <mr-iid> [clickup-task-id]
# Starts an MR review (ADR 0003): checks the MR is open (drafts too), creates
# .work/mr-<iid>/ and checks the MR's head out into a review worktree. Run it
# again to move the worktree to the MR's new head. The user's branch and
# uncommitted work are never touched, so a dirty checkout is fine.
# A ClickUp id given here is stored and wins over one found later; a run
# without one keeps the stored id.
set -euo pipefail
source "$(dirname "$0")/config.sh"
require git glab jq

IID="${1:?usage: start-review.sh <mr-iid> [clickup-task-id]}"
CLICKUP_ID="${2:-}"
case "$IID" in
  ''|*[!0-9]*) echo "The MR iid must be a number, the 142 in !142. Got: $IID" >&2; exit 1 ;;
esac
TASK="mr-$IID"
DIR="$(task_dir "$TASK")"
WT="$(review_worktree "$TASK")"

if ! MR_JSON="$(glab api "projects/:id/merge_requests/$IID" 2>&1)"; then
  echo "Could not read MR !$IID with glab:" >&2
  printf '%s\n' "$MR_JSON" >&2
  exit 1
fi
MR_STATE="$(jq -r '.state // empty' <<<"$MR_JSON")"
case "$MR_STATE" in
  opened) ;;
  merged|closed) echo "MR !$IID is $MR_STATE: there's nothing to review." >&2; exit 1 ;;
  *) echo "MR !$IID is ${MR_STATE:-in an unknown state}: only open MRs (drafts too) can be reviewed." >&2; exit 1 ;;
esac

TARGET="$(jq -r '.target_branch // empty' <<<"$MR_JSON")"
[ -n "$TARGET" ] || { echo "glab gave no target branch for MR !$IID." >&2; exit 1; }

# The MR's head through GitLab's own ref, so a fork MR works too. The target
# branch, fetched too, is what the router counts the MR's changes against.
git fetch --quiet origin "refs/merge-requests/$IID/head"
HEAD_SHA="$(git rev-parse FETCH_HEAD)"
git fetch --quiet origin "$TARGET"

git worktree prune
if [ -f "$WT/.git" ]; then   # a worktree has a .git file; a bare folder in .git/ would fool git -C
  git -C "$WT" checkout --quiet --detach "$HEAD_SHA"
else
  mkdir -p "$(dirname "$WT")"
  git worktree add --quiet --detach "$WT" "$HEAD_SHA"
fi

state_init_review "$TASK" "$IID"
state_set_target_branch "$TASK" "$TARGET"
[ -z "$CLICKUP_ID" ] || state_set_clickup_id "$TASK" "$CLICKUP_ID"

DRAFT=""; [ "$(jq -r '.draft // false' <<<"$MR_JSON")" = true ] && DRAFT=" (draft)"
echo "MR !$IID$DRAFT at ${HEAD_SHA:0:12}. Review worktree: $WT. Work folder: ${DIR#"$REPO_ROOT"/}"
