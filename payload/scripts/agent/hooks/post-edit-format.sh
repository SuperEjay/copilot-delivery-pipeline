#!/usr/bin/env bash
# postToolUse hook: after an agent edits or creates a file, run FORMAT_CMD
# (from .agent.env) on that file, e.g. "npx prettier --write". It costs no
# tokens, and format-only lint failures stop appearing in run-checks.sh.
# No-op when FORMAT_CMD is empty. Never blocks: this hook always exits 0.

input="$(cat)"
echo '{}'
command -v jq >/dev/null 2>&1 || exit 0
cwd="$(jq -r '.cwd // empty' <<<"$input" 2>/dev/null)"; [ -n "$cwd" ] && cd "$cwd" 2>/dev/null
[ -f .agent.env ] && source .agent.env 2>/dev/null
[ -n "${FORMAT_CMD:-}" ] || exit 0

tool="$(jq -r '.toolName // .tool_name // ""' <<<"$input")"
case "$tool" in
  edit|create|Edit|Write|MultiEdit|editFiles|createFile|create_file|insert_edit_into_file|replace_string_in_file|multi_replace_string_in_file|apply_patch|str_replace*) ;;
  *) exit 0 ;;
esac

jq -r '(.toolArgs // .tool_input // {}) | (if type == "string" then (fromjson? // {}) else . end)
       | [.path, .file_path, .filePath, (.files // [] | .[]?)] | map(select(type == "string")) | .[]' <<<"$input" 2>/dev/null |
while IFS= read -r f; do
  case "$f" in .work/*|*/.work/*) continue ;; esac
  [ -f "$f" ] || continue
  # shellcheck disable=SC2086
  $FORMAT_CMD "$f" >/dev/null 2>&1 || true
done
exit 0
