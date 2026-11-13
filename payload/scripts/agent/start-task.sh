#!/usr/bin/env bash
# Usage: start-task.sh <clickup-task-id> <short-slug>
# Creates (or switches to) the task branch and the .work/<task-id>/ folder.
set -euo pipefail
source "$(dirname "$0")/config.sh"

TASK="${1:?usage: start-task.sh <clickup-task-id> <short-slug>}"
SLUG="${2:?usage: start-task.sh <clickup-task-id> <short-slug>}"
BRANCH="$BRANCH_PREFIX/$TASK-$SLUG"
DIR="$(task_dir "$TASK")"

mkdir -p "$DIR/logs"

if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  echo "You have uncommitted changes. Commit or stash them first." >&2
  exit 1
fi

git fetch origin "$BASE_BRANCH" --quiet
if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
  git switch --quiet "$BRANCH"
else
  git switch --quiet -c "$BRANCH" "origin/$BASE_BRANCH"
fi

if [ ! -f "$DIR/state.env" ]; then
  printf 'TASK=%s\nBRANCH=%s\nREVIEW_ROUND=0\n' "$TASK" "$BRANCH" > "$DIR/state.env"
fi

echo "Task $TASK on branch $BRANCH. Work folder: ${DIR#"$REPO_ROOT"/}"
