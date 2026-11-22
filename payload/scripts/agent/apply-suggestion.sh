#!/usr/bin/env bash
# Usage: apply-suggestion.sh <task-id> <thread-id>
# Applies the GitLab ```suggestion block of one thread in
# .work/<task-id>/review.json to the working tree. It never commits: the
# review-responder commits, runs the checks, and the verifier runs before the
# push. Never use GitLab's "Apply suggestion" button instead: it commits on the
# remote and skips the tests.
#
# ```suggestion:-N+M replaces the commented line (the thread's new_line) with the N
# lines above it and the M below it; a bare ```suggestion is -0+0, and an empty
# block deletes the lines. The lines replaced are the ones the reviewer saw, at
# the thread's head_sha. Each block goes where those lines still are: at the
# same line numbers, or else where they appear exactly once in the file.
#
# Exit 0 applied. Exit 3 when it can't apply (no block or several, no line or
# head_sha, stale lines): nothing is written, and the review-responder
# makes the fix by hand. Exit 1 on a usage error or an unknown thread.
set -euo pipefail
source "$(dirname "$0")/config.sh"
require git jq

TASK="${1:?usage: apply-suggestion.sh <task-id> <thread-id>}"
THREAD="${2:?usage: apply-suggestion.sh <task-id> <thread-id>}"
JSON="$(task_dir "$TASK")/review.json"
[ -f "$JSON" ] || { echo "No ${JSON#"$REPO_ROOT"/}. Run fetch-duo-review.sh $TASK first." >&2; exit 1; }
T="$(jq -c --arg id "$THREAD" 'map(select(.id == $id)) | .[0] // empty' "$JSON")"
[ -n "$T" ] || { echo "No thread $THREAD in ${JSON#"$REPO_ROOT"/}." >&2; exit 1; }

refuse() { echo "Can't apply the suggestion of thread $THREAD: $1. Make the fix by hand." >&2; exit 3; }

FILE="$(jq -r '.file // empty' <<< "$T")"
LINE="$(jq -r '.new_line // empty' <<< "$T")"
SHA="$(jq -r '.head_sha // empty' <<< "$T")"
BODY="$(jq -r '.body // ""' <<< "$T")"
[ -n "$FILE" ] && [ -n "$LINE" ] || refuse "it isn't on a line of the new code"
[ -n "$SHA" ] || refuse "review.json has no head_sha for it (fetch the review again)"
[ -f "$REPO_ROOT/$FILE" ] || refuse "$FILE doesn't exist in the working tree"
git -C "$REPO_ROOT" cat-file -e "$SHA:$FILE" 2>/dev/null || refuse "commit $SHA or $FILE in it isn't available"

# ---------- the block: N, M and the new lines ----------
# Every block is anchored on the commented line, so two blocks in one comment
# always overlap: they are alternatives, and choosing one is a hand fix.
blocks=0; fence=""; N=0; M=0; NEW_TEXT=""; nl=$'\n'
while IFS= read -r l || [ -n "$l" ]; do
  l="${l%$'\r'}"
  if [ -z "$fence" ]; then
    if [[ "$l" =~ ^(\`{3,})suggestion(:-([0-9]+)\+([0-9]+))?[[:space:]]*$ ]]; then
      fence="${BASH_REMATCH[1]}"; N="${BASH_REMATCH[3]:-0}"; M="${BASH_REMATCH[4]:-0}"; blocks=$(( blocks + 1 ))
    fi
  elif [[ "$l" =~ ^\`{3,}[[:space:]]*$ ]] && [ "${l%%[[:space:]]*}" = "$fence" ]; then
    fence=""
  else
    NEW_TEXT+="$l$nl"
  fi
done <<< "$BODY"
[ -z "$fence" ] || refuse "its suggestion block isn't closed"
[ "$blocks" -gt 0 ] || refuse "it has no suggestion block"
[ "$blocks" -eq 1 ] || refuse "it offers $blocks suggestion blocks, which are alternatives"

# ---------- the file then (as the reviewer saw it) and now ----------
mapfile -t OLD < <(git -C "$REPO_ROOT" show "$SHA:$FILE")
CUR_RAW="$(cat "$REPO_ROOT/$FILE"; printf x)"; CUR_RAW="${CUR_RAW%x}"
ENDS_NL=0; [ "${CUR_RAW: -1}" = $'\n' ] && ENDS_NL=1
mapfile -t CUR < <(printf '%s' "$CUR_RAW")

# same <cur-start> <old-start> <count>: the current lines from cur-start match
# the old lines from old-start (all 0-based).
same() {
  local i
  [ $(( $1 + $3 )) -le "${#CUR[@]}" ] || return 1
  for (( i = 0; i < $3; i++ )); do [ "${CUR[$1 + i]}" = "${OLD[$2 + i]}" ] || return 1; done
}

# ---------- where the lines are now ----------
OS=$(( LINE - 1 - N )); CNT=$(( N + M + 1 ))
[ "$OS" -ge 0 ] && [ $(( OS + CNT )) -le "${#OLD[@]}" ] || refuse "its lines are outside $FILE at $SHA"
if same "$OS" "$OS" "$CNT"; then
  AT="$OS"
else
  AT=""; hits=0
  for (( s = 0; s + CNT <= ${#CUR[@]}; s++ )); do
    if same "$s" "$OS" "$CNT"; then AT="$s"; hits=$(( hits + 1 )); fi
  done
  [ "$hits" -eq 1 ] || refuse "the lines it replaces are stale (changed since the review, or found $hits times)"
fi

REPL=()
[ -z "$NEW_TEXT" ] || mapfile -t REPL < <(printf '%s' "$NEW_TEXT")
NEW=("${CUR[@]:0:AT}" "${REPL[@]}" "${CUR[@]:AT + CNT}")

# Written in place, so the file keeps its mode; a file without a final
# newline keeps it that way.
{
  for i in "${!NEW[@]}"; do
    [ "$i" -eq 0 ] || printf '\n'
    printf '%s' "${NEW[i]}"
  done
  [ "${#NEW[@]}" -eq 0 ] || [ "$ENDS_NL" = 0 ] || printf '\n'
} > "$REPO_ROOT/$FILE"

where="$FILE:$(( AT + 1 ))"; [ "$CNT" -gt 1 ] && where+="-$(( AT + CNT ))"
echo "Applied the suggestion of thread $THREAD to $where (not committed)."
