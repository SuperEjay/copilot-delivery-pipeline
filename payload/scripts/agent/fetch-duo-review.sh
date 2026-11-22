#!/usr/bin/env bash
# Usage: fetch-duo-review.sh <task-id> [--force]
# Writes .work/<task-id>/review.json: only unresolved, resolvable threads,
# filtered to DUO_USERNAMES when that's set, trimmed to what an agent needs.
# Counts review rounds and refuses past MAX_REVIEW_ROUNDS unless --force.
# A fetch that returns the same set of threads as the last one is the same
# round, so running this twice for one review doesn't use up a round.
#
# For an MR review (task mr-<iid>, ADR 0003) it writes .work/mr-<iid>/threads.json
# instead: every author's open threads (unresolved ones, and plain comments,
# not system notes), for the reviewer to read first. DUO_USERNAMES doesn't
# filter them, and no round is counted.
set -euo pipefail
source "$(dirname "$0")/config.sh"
require glab jq

TASK="${1:?usage: fetch-duo-review.sh <task-id> [--force]}"
FORCE="${2:-}"
DIR="$(task_dir "$TASK")"
MR_IID="$(state_mr_iid "$TASK")" || exit 1

# trimmed: the jq filter that keeps what an agent needs from one discussion.
TRIM='{
    id,
    author: .notes[0].author.username,
    resolvable: (.notes[0].resolvable == true),
    file: (.notes[0].position.new_path // .notes[0].position.old_path),
    line: (.notes[0].position.new_line // .notes[0].position.old_line),
    body: .notes[0].body,
    replies: [ .notes[1:][] | {author: .author.username, body: (.body | .[0:400])} ]
  }'

if state_is_review "$TASK"; then
  OUT="$DIR/threads.json"
  TMP="$OUT.tmp"; trap 'rm -f "$TMP"' EXIT
  glab api --paginate "projects/:id/merge_requests/$MR_IID/discussions?per_page=100" \
  | jq -s "[ (add // [])[]
            | select((.notes[0].system == true) | not)
            | select(if .notes[0].resolvable == true then (.notes[0].resolved | not) else true end)
            | $TRIM ]" > "$TMP"
  mv "$TMP" "$OUT"
  echo "$(jq 'length' "$OUT") open thread(s) from every author in ${OUT#"$REPO_ROOT"/}"
  exit 0
fi
LAST_ROUND="$(state_review_round "$TASK")"
LAST_IDS="$(state_review_ids "$TASK")"

OUT="$DIR/review.json"
TMP="$OUT.tmp"; trap 'rm -f "$TMP"' EXIT
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
            new_line: .notes[0].position.new_line,
            head_sha: .notes[0].position.head_sha,
            body: .notes[0].body,
            replies: [ .notes[1:][] | {author: .author.username, body: (.body | .[0:400])} ]
          }
      ]' > "$TMP"

IDS="$(jq -r '[.[].id] | sort | join(",")' "$TMP" | cksum | cut -d' ' -f1)"
if [ -n "$LAST_IDS" ] && [ "$IDS" = "$LAST_IDS" ]; then
  ROUND="$LAST_ROUND"; note=" (same threads as the last fetch, not a new round)"
else
  ROUND=$(( LAST_ROUND + 1 )); note=""
  if [ "$ROUND" -gt "$MAX_REVIEW_ROUNDS" ] && [ "$FORCE" != "--force" ]; then
    echo "Review round $ROUND would exceed MAX_REVIEW_ROUNDS=$MAX_REVIEW_ROUNDS." >&2
    echo "Look at the remaining threads yourself, or re-run with --force." >&2
    exit 3
  fi
  state_set_review "$TASK" "$ROUND" "$IDS"
fi
mv "$TMP" "$OUT"

count="$(jq 'length' "$OUT")"
echo "Round $ROUND: $count unresolved thread(s) in ${OUT#"$REPO_ROOT"/}$note"
if [ "$count" -gt 0 ]; then
  jq -r '.[] | "  \(.id[0:8])  \(.file // "(general)"):\(.line // "-")  \(.body | split("\n")[0] | .[0:100])"' "$OUT"
fi
