#!/usr/bin/env bash
# Usage: post-review-thread.sh <mr-iid> <CR-n>
# Posts one finding of an MR review (ADR 0003) from .work/mr-<iid>/code-review.md
# as its own discussion thread on the MR, then records the thread id under the
# finding as "- **Thread:** <id>". The finding must be marked
# "- **Decision:** post" and not posted yet.
#
# The thread is on the diff line when the finding's `file:line` is inside the
# MR's diff (an added line, or an unchanged line shown in a hunk), and a general
# thread naming the location otherwise. It starts with
#   **[pipeline review] CR-n · <severity> · <category>**
# so the author can tell it's AI-assisted. It refuses when the MR moved on
# since the review: run /review-mr <iid> again first.
# The hook guard asks you to confirm every call.
set -euo pipefail
source "$(dirname "$0")/config.sh"
require git glab jq

IID="${1:?usage: post-review-thread.sh <mr-iid> <CR-n>}"
CR="${2:?usage: post-review-thread.sh <mr-iid> <CR-n>}"
TASK="mr-$IID"
DIR="$(task_dir "$TASK")"
REVIEW="$DIR/code-review.md"
REL="${REVIEW#"$REPO_ROOT"/}"
WT="$(review_worktree "$TASK")"

if [ ! -f "$DIR/state.env" ] || [ "$(state_kind "$TASK")" != MR_REVIEW ]; then
  echo "No MR review of !$IID yet. Run /review-mr $IID first." >&2; exit 1
fi
case "$CR" in CR-[0-9]*) ;; *) echo "Not a finding id: $CR (use CR-<n>)." >&2; exit 1 ;; esac

# _block: the finding's lines, from its "### CR-n " heading to the next heading.
_block() { awk -v id="$CR" '/^#{2,3} / { on = ($1 == "###" && $2 == id) } on' "$REVIEW"; }
_value() { _block | sed -n "s/^- \*\*$1:\*\*[[:space:]]*//p" | tail -n1 | sed -E 's/[*_`]//g; s/[[:space:]]+$//'; }

BLOCK="$( [ -f "$REVIEW" ] && _block || true)"
[ -n "$BLOCK" ] || { echo "No $CR in $REL." >&2; exit 1; }
DECISION="$(_value Decision | awk '{ print tolower($1) }')"
[ "$DECISION" = post ] || { echo "$CR is marked ${DECISION:-nothing}, not post. Only findings marked post are posted." >&2; exit 1; }
THREAD="$(_value Thread)"
[ -z "$THREAD" ] || { echo "$CR is already posted (thread $THREAD)." >&2; exit 1; }

# Heading: "### CR-n · <severity> · <category> · `file:line`"
HEADING="$(head -n1 <<<"$BLOCK")"
SEVERITY="$(awk -F' · ' '{ print $2 }' <<<"$HEADING")"
CATEGORY="$(awk -F' · ' '{ print $3 }' <<<"$HEADING")"
LOCATION="$(grep -oE '`[^`]+`' <<<"$HEADING" | head -n1 | tr -d '`' || true)"
FILE=""; LINE=""
if [[ $LOCATION =~ ^([^:]+):([0-9]+) ]]; then FILE="${BASH_REMATCH[1]}"; LINE="${BASH_REMATCH[2]}"; fi

# The MR must still be at the head that was reviewed.
MR_JSON="$(glab api "projects/:id/merge_requests/$IID")"
BASE_SHA="$(jq -r '.diff_refs.base_sha // empty' <<<"$MR_JSON")"
START_SHA="$(jq -r '.diff_refs.start_sha // empty' <<<"$MR_JSON")"
HEAD_SHA="$(jq -r '.diff_refs.head_sha // empty' <<<"$MR_JSON")"
REVIEWED="$(git -C "$WT" rev-parse HEAD 2>/dev/null || true)"
if [ -z "$HEAD_SHA" ] || [ "$HEAD_SHA" != "$REVIEWED" ]; then
  echo "MR !$IID is at ${HEAD_SHA:0:12} now, but the review is of ${REVIEWED:0:12}. Run /review-mr $IID to review the new commits before posting." >&2
  exit 1
fi

# Where the line is in the diff: "new <n>" for an added line, "context <old> <new>"
# for an unchanged one inside a hunk, nothing when it's outside the diff.
SPOT=""
if [ -n "$FILE" ] && git -C "$WT" cat-file -e "$BASE_SHA^{commit}" 2>/dev/null; then
  SPOT="$(git -C "$WT" diff --no-color -U3 "$BASE_SHA" "$HEAD_SHA" -- "$FILE" | awk -v want="$LINE" '
    /^@@/ { split($2, o, ","); split($3, n, ","); old = -o[1]; new = n[1]; inhunk = 1; next }
    !inhunk { next }
    /^\+/ { if (new == want) { print "new " new; exit } new++; next }
    /^-/  { old++; next }
    /^ /  { if (new == want) { print "context " old " " new; exit } old++; new++; next }')"
fi

# The thread's text: the header, then the finding without its bookkeeping lines.
BODY="**[pipeline review] $CR · $SEVERITY · $CATEGORY**"
[ -z "$SPOT" ] && [ -n "$LOCATION" ] && BODY="$BODY"$'\n'"Location: \`$LOCATION\`"
BODY="$BODY"$'\n\n'"$(tail -n +2 <<<"$BLOCK" | grep -vE '^- \*\*(Decision|Thread|Status|Route):\*\*' | sed -e :a -e '/^[[:space:]]*$/{$d;N;ba' -e '}')"

TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
read -r kind a b <<<"${SPOT:-none}"
case "$kind" in
  new)     jq -n --arg body "$BODY" --arg f "$FILE" --argjson n "$a" --arg b "$BASE_SHA" --arg s "$START_SHA" --arg h "$HEAD_SHA" \
             '{body: $body, position: {position_type: "text", base_sha: $b, start_sha: $s, head_sha: $h, old_path: $f, new_path: $f, new_line: $n}}' > "$TMP" ;;
  context) jq -n --arg body "$BODY" --arg f "$FILE" --argjson o "$a" --argjson n "$b" --arg b "$BASE_SHA" --arg s "$START_SHA" --arg h "$HEAD_SHA" \
             '{body: $body, position: {position_type: "text", base_sha: $b, start_sha: $s, head_sha: $h, old_path: $f, new_path: $f, old_line: $o, new_line: $n}}' > "$TMP" ;;
  *)       jq -n --arg body "$BODY" '{body: $body}' > "$TMP" ;;
esac

DID="$(glab api -X POST "projects/:id/merge_requests/$IID/discussions" -H "Content-Type: application/json" --input "$TMP" | jq -r '.id // empty')"
[ -n "$DID" ] || { echo "GitLab gave no thread id for $CR; check the MR before posting again." >&2; exit 1; }

# Record the thread under the finding, after its Decision line.
awk -v id="$CR" -v did="$DID" '
  /^#{2,3} / { on = ($1 == "###" && $2 == id) }
  { print }
  on && /^- \*\*Decision:\*\*/ { print "- **Thread:** " did; on = 0 }' "$REVIEW" > "$REVIEW.tmp"
mv "$REVIEW.tmp" "$REVIEW"

where="a general thread"; [ -n "$SPOT" ] && where="$FILE:$LINE"
echo "Posted $CR on $where (thread $DID)."
