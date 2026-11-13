#!/usr/bin/env bash
# Usage: push-branch.sh <task-id>
# Pushes the task's branch (never forced). Used by the review responder after
# the user approved the triage. The pipeline guard asks the user to confirm.
set -euo pipefail
source "$(dirname "$0")/config.sh"

TASK="${1:?usage: push-branch.sh <task-id>}"
load_state "$TASK"
current="$(git branch --show-current)"
[ "$current" = "$BRANCH" ] || { echo "On branch $current, expected $BRANCH. Not pushing." >&2; exit 1; }
git push --quiet origin "$BRANCH"
echo "Pushed $BRANCH ($(git rev-parse --short HEAD))."
