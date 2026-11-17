#!/usr/bin/env bash
# Evidence helpers and the evidence approval record. Source after config.sh;
# don't run. The approval record (evidence/APPROVED) is written and checked only
# here: approve-evidence.sh writes it, upload-evidence.sh and the ship gate check it.

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# Print "<x or space>\t<file>\t<caption>" for each evidence line in the manifest:
#   - [x] AC-1 · `AC-1-export-button.png` · Export button on the invoice list
manifest_items() {
  grep -E '^- \[[ xX]\] .*`[^`]+`' "$1" | while IFS= read -r line; do
    mark="$(printf '%s' "$line" | sed -E 's/^- \[([ xX])\].*/\1/' | tr 'X' 'x')"
    file="$(printf '%s' "$line" | sed -E 's/^[^`]*`([^`]+)`.*/\1/')"
    caption="$(printf '%s' "$line" | sed -E 's/^- \[[ xX]\] //')"
    printf '%s\t%s\t%s\n' "$mark" "$file" "$caption"
  done
}

# approval_write <task> [file...]
# Record the user's approval of the manifest and these evidence files at HEAD.
# Any earlier upload record is dropped, since the approved set is new.
approval_write() {
  local task="$1"; shift
  local ev f
  ev="$(task_dir "$task")/evidence"
  {
    echo "# approved $(date -u +%Y-%m-%dT%H:%M:%SZ) by $(git config user.name || echo unknown) at commit $(git rev-parse HEAD)"
    echo "$(sha256 "$ev/evidence.md")  evidence.md"
    for f in "$@"; do echo "$(sha256 "$ev/$f")  $f"; done
  } > "$ev/APPROVED"
  rm -f "$ev/UPLOADED"
}

# approval_verify <task>
# Succeeds when the approval exists, was given at HEAD, and no approved file
# changed since. Prints the approved evidence files (not the manifest), one per
# line, relative to the evidence folder. On failure, prints why to stderr and
# returns 1. Approvals that recorded a short sha (v1.1.0) still match.
approval_verify() {
  local ev approved at head hash name files=""
  ev="$(task_dir "$1")/evidence"; approved="$ev/APPROVED"
  if [ ! -f "$approved" ]; then
    echo "Evidence is not approved yet. Review ${ev#"$REPO_ROOT"/}/evidence.md, then run:" >&2
    echo "  scripts/agent/approve-evidence.sh $1" >&2
    return 1
  fi
  at="$(sed -nE '1s/.* at commit ([0-9a-f]{7,40}).*/\1/p' "$approved")"
  head="$(git rev-parse HEAD)"
  if [ -z "$at" ] || [ "${head#"$at"}" = "$head" ]; then
    echo "Evidence was approved at commit ${at:-(unknown)}, but HEAD is now ${head:0:7}." >&2
    echo "The screenshots may not show the code that ships. Re-capture with the evidence agent and approve again." >&2
    return 1
  fi
  while read -r hash name; do
    case "$hash" in "#"*|"") continue ;; esac
    [ -f "$ev/$name" ] || { echo "Approved file is gone: $name. Re-approve." >&2; return 1; }
    if [ "$(sha256 "$ev/$name")" != "$hash" ]; then
      echo "$name changed after approval. Review it again and re-run approve-evidence.sh." >&2
      return 1
    fi
    [ "$name" = "evidence.md" ] || files="$files$name"$'\n'
  done < "$approved"
  printf '%s' "$files"
}

# approval_summary <task>: the approval's header, e.g. "approved <time> by <name> at commit <sha>".
approval_summary() { head -n1 "$(task_dir "$1")/evidence/APPROVED" | sed 's/^# //'; }
