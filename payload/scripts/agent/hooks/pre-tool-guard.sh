#!/usr/bin/env bash
# preToolUse hook: runs before every agent tool call, reads the call as JSON on
# stdin and prints one decision: {} (allow), "deny" (blocked, with a reason
# the agent sees) or "ask" (VS Code asks you to confirm).
#
# It turns the pipeline's rules into enforced ones:
#   deny  approving evidence, touching evidence/APPROVED|UPLOADED
#   deny  reading or printing secrets (tokens, .auth/ sessions, ~/.ssh)
#   deny  destructive git (force push, reset --hard, clean -f, branch -D, --no-verify)
#   deny  raw git push / glab write calls (scripts must be used)
#   deny  raw test commands (run-checks.sh / capture-evidence.sh must be used)
#   deny  agent edits to pipeline config (agents, hooks, prompts, instructions, scripts, .agent.env)
#   ask   anything that publishes: create-mr, push-branch, upload-evidence, ClickUp writes
#
# Every decision other than allow is logged to .work/hooks.log.
# To switch the guard off for a session, start VS Code with PIPELINE_GUARD=off.

input="$(cat)"

decide() {   # decide <allow|deny|ask> [reason]
  if [ "$1" != "allow" ]; then
    mkdir -p .work 2>/dev/null && printf '%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$1" "$tool" "${2:-}" >> .work/hooks.log 2>/dev/null
    jq -n --arg d "$1" --arg r "${2:-}" '{permissionDecision: $d, permissionDecisionReason: $r}'
  else
    echo '{}'
  fi
  exit 0
}

[ "${PIPELINE_GUARD:-on}" = "off" ] && { echo '{}'; exit 0; }
command -v jq >/dev/null 2>&1 || { echo '{"permissionDecision":"deny","permissionDecisionReason":"Pipeline guard needs jq installed."}'; exit 0; }

cwd="$(jq -r '.cwd // empty' <<<"$input" 2>/dev/null)"
[ -n "$cwd" ] && cd "$cwd" 2>/dev/null

tool="$(jq -r '.toolName // .tool_name // ""' <<<"$input")"
args="$(jq -c '(.toolArgs // .tool_input // {}) | if type == "string" then (fromjson? // {command: .}) else . end' <<<"$input")"

# Tool families, covering Copilot harness names and older/alternate names.
is_shell=false; is_edit=false; is_read=false
case "$tool" in
  bash|powershell|shell|Bash|runInTerminal|run_in_terminal|execute*|terminal*) is_shell=true ;;
  edit|create|Edit|Write|MultiEdit|NotebookEdit|editFiles|createFile|create_file|insert_edit_into_file|replace_string_in_file|multi_replace_string_in_file|apply_patch|str_replace*) is_edit=true ;;
  view|Read|readFile|read_file|NotebookRead) is_read=true ;;
esac

# ---------- shell commands ----------
if $is_shell; then
  cmd="$(jq -r '.command // .cmd // .script // ([.. | strings] | join(" "))' <<<"$args")"
  has() { grep -qE -- "$1" <<<"$cmd"; }

  has 'approve-evidence\.sh' &&
    decide deny "Evidence approval is the user's job. Ask them to review evidence.md and run approve-evidence.sh themselves."
  has 'evidence/(APPROVED|UPLOADED)' &&
    decide deny "evidence/APPROVED and evidence/UPLOADED are managed by the user's approval and the upload script only."

  has '(\$\{?[A-Za-z_]*(TOKEN|SECRET|PASSWORD|API_KEY)|(^|[;&|[:space:]])(printenv|env|set|export -p)([[:space:]]*($|[;&|>]))|\.auth/|\.ssh/|pk_[A-Za-z0-9]{6,}|glpat-|\.netrc|\.npmrc)' &&
    decide deny "This command could read or print a secret (token, saved login session or credentials). Agents never need those values; the scripts use them directly."

  has 'git[[:space:]]+push.*(--force|[[:space:]]-f([[:space:]]|$)|--force-with-lease|--delete|[[:space:]]:[^[:space:]])' &&
    decide deny "Force pushes and remote deletes are not allowed."
  has 'git[[:space:]]+(reset[[:space:]]+--hard|clean[[:space:]]+-[a-zA-Z]*f|branch[[:space:]]+-D|checkout[[:space:]]+--[[:space:]]+\.|restore[[:space:]]+\.)' &&
    decide deny "Destructive git commands that throw away work are not allowed. Ask the user."
  has 'git[[:space:]].*--no-verify' &&
    decide deny "Skipping git hooks (--no-verify) is not allowed. Fix what the hook reports instead."

  has '(^|[;&|(][[:space:]]*)git[[:space:]]+push' &&
    decide deny "Don't push directly. Use scripts/agent/create-mr.sh (shipper) or scripts/agent/push-branch.sh <task-id> (after the user approved the triage)."
  has 'glab[[:space:]]+(mr[[:space:]]+(create|update|merge|close|approve|revoke|note|delete)|api.*-X[[:space:]]*(POST|PUT|PATCH|DELETE)|api.*--method[[:space:]]*(POST|PUT|PATCH|DELETE))' &&
    decide deny "Don't write to GitLab directly. Use scripts/agent/create-mr.sh or scripts/agent/reply-thread.sh."
  has 'curl.*api\.clickup\.com' &&
    decide deny "Don't call the ClickUp API directly. Use scripts/agent/clickup.sh."

  has '(^|[;&|(][[:space:]]*)((npm|pnpm|yarn|bun)[[:space:]]+(run[[:space:]]+)?test|npx[[:space:]]+(jest|vitest|mocha|playwright[[:space:]]+test|cypress[[:space:]]+run)|pytest|go[[:space:]]+test|cargo[[:space:]]+test|dotnet[[:space:]]+test|(npm|pnpm|yarn)[[:space:]]+(run[[:space:]]+)?(lint|typecheck|type-check)|npx[[:space:]]+(eslint|tsc))' &&
    decide deny "Run tests, lint and typechecks only through scripts/agent/run-checks.sh <task-id> <checks> (or capture-evidence.sh for evidence). It keeps the output short."

  if has 'scripts/agent/(create-mr|push-branch)\.sh'; then
    decide ask "This pushes code to GitLab. Approve only if you've given the go-ahead."
  fi
  if has 'upload-evidence\.sh' && ! has 'upload-evidence\.sh[[:space:]]+[^[:space:]]+[[:space:]]+--check'; then
    decide ask "This uploads your approved evidence to ClickUp."
  fi
  if has 'clickup\.sh[[:space:]]+(comment|status|attach)'; then
    decide ask "This writes to the ClickUp task (comment, status or attachment)."
  fi
  decide allow
fi

# ---------- file edits ----------
if $is_edit || $is_read; then
  paths="$(jq -r '[.path, .file_path, .filePath, .filename, .uri, (.files // [] | .[]?), (.filePaths // [] | .[]?)] | map(select(type == "string")) | .[]' <<<"$args" 2>/dev/null)"
  [ -z "$paths" ] && paths="$(jq -r '[.. | strings | select(test("^[./~A-Za-z0-9_-]+/|\\.[A-Za-z0-9]{1,6}$"))] | .[]' <<<"$args" 2>/dev/null)"
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    if grep -qE '(^|/)\.auth/|(^|/)\.ssh/|(^|/)\.netrc$|(^|/)\.npmrc$' <<<"$p"; then
      decide deny "That file holds credentials or a saved login session. Agents never need to read or change it."
    fi
    if $is_edit; then
      if grep -qE 'evidence/(APPROVED|UPLOADED)$' <<<"$p"; then
        decide deny "evidence/APPROVED and evidence/UPLOADED are managed by the user's approval and the upload script only."
      fi
      if grep -qE '(^|/)\.github/(agents|hooks|prompts)/|(^|/)\.github/copilot-instructions\.md$|(^|/)scripts/agent/|(^|/)\.agent\.env$' <<<"$p"; then
        decide deny "Pipeline config (agents, models, hooks, prompts, instructions, scripts, .agent.env) is user-owned. Tell the user what you'd change and why."
      fi
    fi
  done <<<"$paths"
fi

decide allow
