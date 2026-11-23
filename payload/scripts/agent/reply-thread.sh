#!/usr/bin/env bash
# Usage: reply-thread.sh <task-id> <discussion-id> <message-file> [--resolve]
# Posts the message file as a reply in an MR discussion thread, starting with
# "**[pipeline]** " so teammates can tell it came from the pipeline, and resolves
# the thread when --resolve is given. In an MR review (task mr-<iid>, ADR 0003)
# --resolve is refused: resolving stays with the MR's author and team.
set -euo pipefail
source "$(dirname "$0")/config.sh"
require glab jq
source "$(dirname "$0")/forge-lib.sh"

TASK="${1:?usage: reply-thread.sh <task-id> <discussion-id> <message-file> [--resolve]}"
DID="${2:?discussion id}"
MSG="${3:?message file}"
RESOLVE="${4:-}"
MR_IID="$(state_mr_iid "$TASK")" || exit 1
if [ "$RESOLVE" = "--resolve" ] && state_is_review "$TASK"; then
  echo "An MR review never resolves a thread (ADR 0003): that stays with the author and the team. Reply without --resolve." >&2
  exit 1
fi
[ -s "$MSG" ] || { echo "Message file is empty or missing: $MSG" >&2; exit 1; }

forge_reply "$MR_IID" "$DID" "**[pipeline]** $(cat "$MSG")" || { echo "Couldn't reply to ${DID:0:8} (see above)." >&2; exit 1; }

if [ "$RESOLVE" = "--resolve" ]; then
  forge_resolve "$MR_IID" "$DID" || { echo "Replied to ${DID:0:8}, but couldn't resolve it (see above)." >&2; exit 1; }
  echo "Replied to and resolved ${DID:0:8}"
else
  echo "Replied to ${DID:0:8}"
fi
