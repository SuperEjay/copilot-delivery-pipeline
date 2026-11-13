#!/usr/bin/env bash
# Usage: upload-evidence.sh <task-id> [--check]
#   --check  only verify the approval is present and still valid (exit 0/1)
#
# Uploads exactly the files you approved (see approve-evidence.sh) to the
# ClickUp task and posts a comment listing them. Refuses if there's no approval,
# or if any approved file or the manifest changed after you approved it.
set -euo pipefail
source "$(dirname "$0")/config.sh"
source "$(dirname "$0")/evidence-lib.sh"

TASK="${1:?usage: upload-evidence.sh <task-id> [--check]}"
MODE="${2:-}"
EV="$(task_dir "$TASK")/evidence"
APPROVED="$EV/APPROVED"

if [ ! -f "$APPROVED" ]; then
  echo "Evidence is not approved yet. Review ${EV#"$REPO_ROOT"/}/evidence.md, then run:" >&2
  echo "  scripts/agent/approve-evidence.sh $TASK" >&2
  exit 1
fi

files=()
while read -r hash name; do
  case "$hash" in "#"*|"") continue ;; esac
  [ -f "$EV/$name" ] || { echo "Approved file is gone: $name. Re-approve." >&2; exit 1; }
  if [ "$(sha256 "$EV/$name")" != "$hash" ]; then
    echo "$name changed after approval. Review it again and re-run approve-evidence.sh." >&2
    exit 1
  fi
  [ "$name" = "evidence.md" ] || files+=("$EV/$name")
done < "$APPROVED"

if [ "$MODE" = "--check" ]; then
  echo "Evidence approval is valid: ${#files[@]} file(s). $(head -n1 "$APPROVED" | sed 's/^# //')"
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
  echo "Development evidence ($(head -n1 "$APPROVED" | sed 's/^# //'))"
  echo
  while IFS=$'\t' read -r mark file caption; do
    [ "$mark" = "x" ] && echo "• $(printf '%s' "$caption" | tr -d '`')"
  done < <(manifest_items "$EV/evidence.md")
} > "$msg"
"$(dirname "$0")/clickup.sh" comment "$TASK" "$msg"

cp "$APPROVED" "$EV/UPLOADED"
echo "Uploaded ${#files[@]} approved file(s) to ClickUp task $TASK."
