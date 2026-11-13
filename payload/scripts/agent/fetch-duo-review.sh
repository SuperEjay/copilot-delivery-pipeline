#!/usr/bin/env bash
# Usage: fetch-duo-review.sh <task-id> [--force]
# Writes .work/<task-id>/review.json: only unresolved, resolvable threads,
# filtered to DUO_USERNAMES when that's set, trimmed to what an agent needs.
# Counts review rounds and refuses past MAX_REVIEW_ROUNDS unless --force.
set -euo pipefail
source "$(dirname "$0")/config.sh"
require glab jq

TASK="${1:?usage: fetch-duo-review.sh <task-id> [--force]}"
FORCE="${2:-}"
DIR="$(task_dir "$TASK")"
load_state "$TASK"
: "${MR_IID:?No MR_IID in state.env. Run create-mr.sh first.}"

ROUND=$(( ${REVIEW_ROUND:-0} + 1 ))
if [ "$ROUND" -gt "$MAX_REVIEW_ROUNDS" ] && [ "$FORCE" != "--force" ]; then
  echo "Review round $ROUND would exceed MAX_REVIEW_ROUNDS=$MAX_REVIEW_ROUNDS." >&2
  echo "Look at the remaining threads yourself, or re-run with --force." >&2
  exit 3
fi

OUT="$DIR/review.json"
glab api --paginate "projects/:id/merge_requests/$MR_IID/discussions?per_page=100" \
| jq -s --arg users "$DUO_USERNAMES" '
    (add // []) as $all
    | ($users | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))) as $u
    | [ $all[]
        | select(.notes[0].resolvable == true and (.notes[0].resolved | not))
        | select(($u | length) == 0 or (.notes[0].author.username as $a | $u | index($a)))
        | {
            id,
            author: .notes[0].author.username,
            file: (.notes[0].position.new_path // .notes[0].position.old_path),
            line: (.notes[0].position.new_line // .notes[0].position.old_line),
            body: .notes[0].body,
            replies: [ .notes[1:][] | {author: .author.username, body: (.body | .[0:400])} ]
          }
      ]' > "$OUT"

set_state "$TASK" REVIEW_ROUND "$ROUND"
count="$(jq 'length' "$OUT")"
echo "Round $ROUND: $count unresolved thread(s) in ${OUT#"$REPO_ROOT"/}"
if [ "$count" -gt 0 ]; then
  jq -r '.[] | "  \(.id[0:8])  \(.file // "(general)"):\(.line // "-")  \(.body | split("\n")[0] | .[0:100])"' "$OUT"
fi
