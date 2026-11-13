#!/usr/bin/env bash
# Helpers shared by approve-evidence.sh and upload-evidence.sh. Source; don't run.

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
