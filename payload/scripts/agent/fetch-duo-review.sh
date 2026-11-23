#!/usr/bin/env bash
# Usage: fetch-duo-review.sh <task-id> [--force]
# Writes .work/<task-id>/review.json: only unresolved, resolvable threads,
# filtered to DUO_USERNAMES when that's set, trimmed to what an agent needs.
# Counts review rounds and refuses past MAX_REVIEW_ROUNDS unless --force.
#
# Threads you already answered are left out (#98): the last note is by your
# glab user (a pipeline reply, or one you typed yourself, or a thread you
# started). When Duo or a teammate writes after you, the thread comes back.
# A new round starts only when a thread is new or has a new note since the last
# round; anything else (nothing at all, or the same open ASK threads) is the
# same round, so fetching again uses up nothing.
#
# For an MR review (task mr-<iid>, ADR 0003) it writes .work/mr-<iid>/threads.json
# instead: every author's open threads (unresolved ones, and plain comments,
# not system notes), for the reviewer to read first. DUO_USERNAMES doesn't
# filter them, and no round is counted.
set -euo pipefail
source "$(dirname "$0")/config.sh"
require glab jq
source "$(dirname "$0")/forge-lib.sh"
source "$(dirname "$0")/duo-round-lib.sh"

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
  ALL_JSON="$(forge_discussions "$MR_IID")" || { echo "Can't read MR !$MR_IID's threads (see above)." >&2; exit 1; }
  jq "[ .[]
            | select((.notes[0].system == true) | not)
            | select(if .notes[0].resolvable == true then (.notes[0].resolved | not) else true end)
            | $TRIM ]" <<<"$ALL_JSON" > "$TMP"
  mv "$TMP" "$OUT"
  echo "$(jq 'length' "$OUT") open thread(s) from every author in ${OUT#"$REPO_ROOT"/}"
  exit 0
fi
LAST_ROUND="$(state_review_round "$TASK")"
LAST_SEEN="$(state_review_seen "$TASK")"
ME="$(forge_me)" || { echo "Can't look up your glab user (glab api user), so threads you already answered can't be skipped. Check glab auth status." >&2; exit 1; }

OUT="$DIR/review.json"
TMP="$OUT.tmp"; trap 'rm -f "$TMP"' EXIT
ALL_JSON="$(forge_discussions "$MR_IID")" || { echo "Can't read MR !$MR_IID's threads (see above)." >&2; exit 1; }
ROUND_JSON="$(round_threads "$ALL_JSON" "$ME" "$DUO_USERNAMES")"
jq '.review' <<<"$ROUND_JSON" > "$TMP"
skipped="$(jq '.skipped' <<<"$ROUND_JSON")"

read -r verdict ROUND seen <<<"$(round_decide "$LAST_ROUND" "$LAST_SEEN" "$(jq -r '.seen' <<<"$ROUND_JSON")" "$MAX_REVIEW_ROUNDS" $FORCE)"
case "$verdict" in
  same) new=0; note=" (same threads as the last fetch, not a new round)" ;;
  new)  new=1; note=""; state_set_review "$TASK" "$ROUND" "$seen" ;;
  over)
    echo "Review round $ROUND would exceed MAX_REVIEW_ROUNDS=$MAX_REVIEW_ROUNDS." >&2
    echo "Look at the remaining threads yourself, or re-run with --force." >&2
    exit 3 ;;
  *) exit 1 ;;
esac
mv "$TMP" "$OUT"

count="$(jq 'length' "$OUT")"
# "Nothing new" whenever no round starts, also with open ASK threads still
# waiting: the review-responder then has nothing to triage again.
[ "$count" -eq 0 ] || echo "Round $ROUND: $count unresolved thread(s) in ${OUT#"$REPO_ROOT"/}$note"
if [ "$new" = 0 ]; then
  if [ "$ROUND" -gt 0 ]; then echo "Nothing new since round $ROUND."; else echo "No unresolved threads to triage yet."; fi
fi
[ "$skipped" -eq 0 ] || echo "$skipped thread(s) already answered by you, skipped."
if [ "$count" -gt 0 ]; then
  jq -r '.[] | "  \(.id[0:8])  \(.file // "(general)"):\(.line // "-")  \(.body | split("\n")[0] | .[0:100])"' "$OUT"
fi
