#!/usr/bin/env bash
# Usage: approve-evidence.sh <task-id>
#
# YOU run this, in your own terminal, after reviewing the evidence.
# 1. Open .work/<task-id>/evidence/evidence.md (Markdown preview shows the screenshots).
# 2. Tick "- [x]" on each item you approve. Leave the rest unticked and write
#    a note under any item you want retaken.
# 3. Run this script and type "approve".
#
# It records a SHA-256 fingerprint of every approved file in evidence/APPROVED.
# upload-evidence.sh and the shipper refuse to go on if any approved file, or
# the manifest, changes afterwards. Agents are instructed never to run this script.
set -euo pipefail
source "$(dirname "$0")/config.sh"
source "$(dirname "$0")/evidence-lib.sh"

TASK="${1:?usage: approve-evidence.sh <task-id>}"
EV="$(task_dir "$TASK")/evidence"
MAN="$EV/evidence.md"
[ -f "$MAN" ] || { echo "No evidence manifest at ${MAN#"$REPO_ROOT"/}." >&2; exit 1; }
if [ ! -t 0 ]; then
  echo "This step needs a person: run it yourself in a terminal." >&2
  exit 1
fi

approved=(); skipped=()
while IFS=$'\t' read -r mark file caption; do
  if [ "$mark" = "x" ]; then
    [ -f "$EV/$file" ] || { echo "Approved item points to a missing file: $file" >&2; exit 1; }
    approved+=("$file")
  else
    skipped+=("$file")
  fi
done < <(manifest_items "$MAN")

echo "Task $TASK evidence"
echo "  Approved (${#approved[@]}):"
for f in ${approved[@]+"${approved[@]}"}; do echo "    ✓ $f"; done
echo "  Not approved (${#skipped[@]}), won't be uploaded:"
for f in ${skipped[@]+"${skipped[@]}"}; do echo "    ✗ $f"; done
if [ "${#approved[@]}" -eq 0 ]; then
  echo "  Nothing ticked. Approving means: ship with no evidence uploaded."
fi
echo

read -r -p "Type 'approve' to approve exactly this set: " answer </dev/tty
[ "$answer" = "approve" ] || { echo "Not approved. Nothing recorded."; exit 1; }

{
  echo "# approved $(date -u +%Y-%m-%dT%H:%M:%SZ) by $(git config user.name || echo unknown) at commit $(git rev-parse --short HEAD)"
  echo "$(sha256 "$MAN")  evidence.md"
  for f in ${approved[@]+"${approved[@]}"}; do echo "$(sha256 "$EV/$f")  $f"; done
} > "$EV/APPROVED"
rm -f "$EV/UPLOADED"
echo "Recorded approval of ${#approved[@]} file(s). The shipper can go ahead."
