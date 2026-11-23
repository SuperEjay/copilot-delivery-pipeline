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
ME="$(glab api user | jq -r '.username // empty')" || ME=""
[ -n "$ME" ] || { echo "Can't look up your glab user (glab api user), so threads you already answered can't be skipped. Check glab auth status." >&2; exit 1; }

OUT="$DIR/review.json"
TMP="$OUT.tmp"; ALL="$OUT.all.tmp"; trap 'rm -f "$TMP" "$ALL"' EXIT
glab api --paginate "projects/:id/merge_requests/$MR_IID/discussions?per_page=100" \
| jq -s --arg users "$DUO_USERNAMES" --arg me "$ME" '
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
            replies: [ .notes[1:][] | {author: .author.username, body: (.body | .[0:400])} ],
            _answered: (.notes[-1].author.username == $me),
            _seen: "\(.id):\(.notes[-1].id)"
          }
      ]' > "$ALL"
jq '[ .[] | select(._answered | not) | del(._answered, ._seen) ]' "$ALL" > "$TMP"
skipped="$(jq '[ .[] | select(._answered) ] | length' "$ALL")"

# IDS: one checksum per open thread and its last note, so a new reply counts.
IDS="$(jq -r '.[] | select(._answered | not) | ._seen' "$ALL" | while IFS= read -r t; do printf '%s' "$t" | cksum | cut -d' ' -f1; done | sort | paste -sd, -)"
new=0
for id in ${IDS//,/ }; do
  case ",$LAST_IDS," in *",$id,"*) ;; *) new=1; break ;; esac
done

if [ "$new" = 0 ]; then
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
