#!/usr/bin/env bash
# Usage: push-branch.sh <task-id>
# Pushes the task's branch (never forced). Used by the review responder after
# the user approved the triage. The pipeline guard asks the user to confirm.
# Refuses unless the ship gate allows it (scripts/agent/ship-gate.sh).
set -euo pipefail
source "$(dirname "$0")/config.sh"
source "$(dirname "$0")/ship-gate.sh"

TASK="${1:?usage: push-branch.sh <task-id>}"
BRANCH="$(state_branch "$TASK")" || exit 1
gate_require "$TASK" push
git push --quiet origin "$BRANCH"
echo "Pushed $BRANCH ($(git rev-parse --short HEAD))."
