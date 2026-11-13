#!/usr/bin/env bash
# Usage: reply-thread.sh <task-id> <discussion-id> <message-file> [--resolve]
# Posts the message file as a reply in an MR discussion thread, and resolves
# the thread when --resolve is given.
set -euo pipefail
source "$(dirname "$0")/config.sh"
require glab

TASK="${1:?usage: reply-thread.sh <task-id> <discussion-id> <message-file> [--resolve]}"
DID="${2:?discussion id}"
MSG="${3:?message file}"
RESOLVE="${4:-}"
load_state "$TASK"
: "${MR_IID:?No MR_IID in state.env.}"
[ -s "$MSG" ] || { echo "Message file is empty or missing: $MSG" >&2; exit 1; }

glab api -X POST "projects/:id/merge_requests/$MR_IID/discussions/$DID/notes" \
  -f "body=$(cat "$MSG")" >/dev/null

if [ "$RESOLVE" = "--resolve" ]; then
  glab api -X PUT "projects/:id/merge_requests/$MR_IID/discussions/$DID" \
    -f "resolved=true" >/dev/null
  echo "Replied to and resolved ${DID:0:8}"
else
  echo "Replied to ${DID:0:8}"
fi
