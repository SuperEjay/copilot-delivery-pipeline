#!/usr/bin/env bash
# Usage: upload-evidence.sh <task-id> [--check]
#   --check  only verify the approval is present and still valid (exit 0/1)
#
# Uploads exactly the files you approved (see approve-evidence.sh) to the
# ClickUp task and posts a comment listing them. Refuses if there's no approval,
# or if any approved file or the manifest changed after you approved it, or if
# HEAD has moved past the commit the evidence was approved at.
set -euo pipefail
source "$(dirname "$0")/config.sh"
source "$(dirname "$0")/evidence-lib.sh"

TASK="${1:?usage: upload-evidence.sh <task-id> [--check]}"
MODE="${2:-}"
EV="$(task_dir "$TASK")/evidence"
APPROVED="$EV/APPROVED"

files=()
approved_files="$(approval_verify "$TASK")" || exit 1
while IFS= read -r name; do
  [ -n "$name" ] && files+=("$EV/$name")
done <<<"$approved_files"

if [ "$MODE" = "--check" ]; then
  echo "Evidence approval is valid: ${#files[@]} file(s). $(approval_summary "$TASK")"
  exit 0
fi

if [ -f "$EV/UPLOADED" ] && cmp -s "$EV/UPLOADED" "$APPROVED"; then
  echo "This approved set was already uploaded. Nothing to do."
  exit 0
fi

if [ "${#files[@]}" -eq 0 ]; then
  echo "Approved set is empty: nothing to upload."
  cp "$APPROVED" "$EV/UPLOADED"
  exit 0
fi

"$(dirname "$0")/clickup.sh" attach "$TASK" "${files[@]}"

msg="$EV/.clickup-evidence-comment.md"
{
  echo "Development evidence ($(approval_summary "$TASK"))"
  echo
  while IFS=$'\t' read -r mark file caption; do
    [ "$mark" = "x" ] && echo "• $(printf '%s' "$caption" | tr -d '`')"
  done < <(manifest_items "$EV/evidence.md")
} > "$msg"
"$(dirname "$0")/clickup.sh" comment "$TASK" "$msg"

cp "$APPROVED" "$EV/UPLOADED"
echo "Uploaded ${#files[@]} approved file(s) to ClickUp task $TASK."
