#!/usr/bin/env bash
# preToolUse hook: runs before every agent tool call, reads the call as JSON on
# stdin and prints one decision: {} (allow), "deny" (blocked, with a reason
# the agent sees) or "ask" (VS Code asks you to confirm).
#
# It turns the pipeline's rules into enforced ones:
#   deny  approving evidence, touching evidence/APPROVED|UPLOADED or verified-head
#   deny  running next-stage.sh from a subagent (only the orchestrator runs the router)
#   deny  agent changes to the task state (.work/<id>/state.env) or the auto run's record
#         (.work/<id>/status.md, which holds stop approvals); reading them is fine
#   deny  sourcing the pipeline's scripts (their functions would skip the scripts' checks)
#   deny  reading or printing secrets (tokens, .auth/ sessions, ~/.ssh)
#   deny  destructive git (force push, reset --hard, clean -f, branch -D, --no-verify)
#   deny  raw git push / glab write calls (scripts must be used)
#   deny  raw test commands (run-checks.sh / capture-evidence.sh must be used)
#   deny  agent edits to pipeline config (agents, hooks, prompts, instructions, scripts, .agent.env),
#         through edit tools or the shell
#   ask   anything that publishes: create-mr, push-branch, upload-evidence, ClickUp writes
#
# Every decision other than allow is logged to .work/hooks.log.
# To switch the guard off for a session, start VS Code with PIPELINE_GUARD=off.
# `pre-tool-guard.sh --list-protected` prints the protected-path table.

# ---------- protected paths ----------
# Paths agents may not change. What each kind blocks is written once, below:
#   kind    shell                        edit tool  read tool
#   secret  denied if mentioned at all   denied     denied
#   record  denied if mentioned at all   denied     allowed
#   config  denied when a write targets  denied     allowed
#   state   denied when a write targets  denied     allowed
# Entries are literal paths; a folder ends in "/" and covers itself and
# everything in it. A "*" segment stands for any one path segment (a task id).
# A match starts at a path segment, anywhere in the path.
# Paths are squashed first (squash_path), so "//", "/./" and "<dir>/.." don't
# hide one. An entry of more than one segment still can't see a write made
# after a cd (cd .work/T-1 && echo x >> status.md) or through a variable
# (d=.work/T-1; echo x >> $d/status.md): the guard is a backstop, not a sandbox.
PROTECTED='
secret  .auth/
secret  .ssh/
secret  .netrc
secret  .npmrc
record  verified-head
record  evidence/APPROVED
record  evidence/UPLOADED
config  .github/agents/
config  .github/hooks/
config  .github/prompts/
config  .github/skills/start-task/
config  .github/skills/fetch-review/
config  .github/copilot-instructions.md
config  scripts/agent/
config  .agent.env
state   state.env
state   .work/*/status.md
'
REASON_secret="That file holds credentials or a saved login session. Agents never need to read or change it."
REASON_record="verified-head and evidence/APPROVED|UPLOADED are written only by the pipeline's scripts: run-checks.sh records the verified commit, and the user approves evidence with approve-evidence.sh. Run scripts/agent/run-checks.sh <task-id> all to re-verify."
REASON_state="state.env (the task's state) and .work/<id>/status.md (the auto run's record, including stop approvals) are written only by the pipeline's scripts: start-task.sh, create-mr.sh, fetch-duo-review.sh and review-signals.sh --mark-reviewed write state.env, next-stage.sh writes status.md. Read them if you need to; don't change them. Only the user approves a stop."
REASON_config="Pipeline config (agents and their models, hooks, prompts, instructions, scripts, .agent.env) is user-owned, from the shell too. Tell the user what you'd change and why."

if [ "${1:-}" = "--list-protected" ]; then
  while read -r kind entry; do [ -n "$kind" ] && printf '%s\t%s\n' "$kind" "$entry"; done <<<"$PROTECTED"
  exit 0
fi

# PATHS_<kind>: one regex per kind matching any of its entries, from the start
# of the entry to the end of a path segment. The caller adds the start boundary.
re_escape() {   # re_escape <text>: escape ERE metacharacters into $REPLY (no subshell, it's per call)
  local s="$1" c i; REPLY=""
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in [].\\[*^\$+?\(\)\{\}\|/]) REPLY+="\\$c" ;; *) REPLY+="$c" ;; esac
  done
}
PATHS_secret=''; PATHS_record=''; PATHS_config=''; PATHS_state=''
ANY_SEG='[^/[:space:]]+'   # what a "*" entry segment matches
while read -r kind entry; do
  [ -n "$kind" ] || continue
  re_escape "${entry%/}"; alt="${REPLY//\\\*/$ANY_SEG}"
  case "$kind" in
    secret) PATHS_secret+="${PATHS_secret:+|}$alt" ;;
    record) PATHS_record+="${PATHS_record:+|}$alt" ;;
    config) PATHS_config+="${PATHS_config:+|}$alt" ;;
    state)  PATHS_state+="${PATHS_state:+|}$alt" ;;
  esac
done <<<"$PROTECTED"
SEG_END='([^A-Za-z0-9._-]|$)'
for kind in secret record config state; do
  v="PATHS_$kind"; printf -v "$v" '(%s)%s' "${!v}" "$SEG_END"
done
SHELL_START='(^|[/[:space:]"'"'"'=<>(`])'   # where a path can start inside a command
PATH_START='(^|/)'                         # where a segment starts inside a path

# squash_path <text>: the paths in a path or command in one shape, into $REPLY,
# so .work//T-1/./status.md or .work/T-1/../T-1/status.md match their entry:
# "//" becomes "/", "/./" becomes "/", and "<dir>/../" is folded away.
SEG_CHAR='[^/[:space:]"'"'"'=<>(`]'           # a character inside one path segment
NON_DOT='[^./[:space:]"'"'"'=<>(`]'           # so ".." itself is never folded away
squash_path() {
  REPLY="$(sed -E -e ':a' -e 's#//+#/#g' -e 's#/\./#/#g' \
    -e "s#$SHELL_START$SEG_CHAR*$NON_DOT$SEG_CHAR*/\.\./#\1#" -e 'ta' <<<"$1")"
}

# split_parts <command>: the command's parts, one per line, into $REPLY. It
# splits at ; | & (so && and || too), in bash rather than sed: BSD/macOS sed
# may write a literal "n" for "\n" in a replacement, which would leave the
# command whole. Redirects to a descriptor (2>&1, >&2, 2>&-) are taken out
# first, so their "&" doesn't split.
FD_REDIRECT='[0-9]*>&[0-9-]+'
split_parts() {
  local s="$1" nl=$'\n'
  while [[ $s =~ $FD_REDIRECT ]]; do s="${s/"${BASH_REMATCH[0]}"/}"; done
  REPLY="${s//[;|&]/$nl}"
}

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
# Set only for a call made inside a subagent; a top-level call names no agent.
subagent="$(jq -r '.agentId // empty' <<<"$input")"
args="$(jq -c '(.toolArgs // .tool_input // {}) | if type == "string" then (fromjson? // {command: .}) else . end' <<<"$input")"

# Tool families, covering Copilot harness names and older/alternate names.
is_shell=false; is_edit=false; is_read=false
case "$tool" in
  bash|powershell|shell|Bash|runInTerminal|run_in_terminal|execute*|terminal*) is_shell=true ;;
  edit|create|Edit|Write|MultiEdit|NotebookEdit|editFiles|createFile|create_file|insert_edit_into_file|replace_string_in_file|multi_replace_string_in_file|apply_patch|str_replace*) is_edit=true ;;
  view|Read|readFile|read_file|NotebookRead) is_read=true ;;
esac

# From here on, [[ =~ ]] ignores case: on macOS and Windows, Scripts/Agent/x.sh
# is the same file as scripts/agent/x.sh. (grep-based command rules don't change.)
shopt -s nocasematch

# ---------- shell commands ----------
if $is_shell; then
  cmd="$(jq -r '.command // .cmd // .script // ([.. | strings] | join(" "))' <<<"$args")"
  has() { grep -qE -- "$1" <<<"$cmd"; }
  squash_path "$cmd"; path_cmd="$REPLY"   # the command, for matching protected paths

  has 'approve-evidence\.sh' &&
    decide deny "Evidence approval is the user's job. Ask them to review evidence.md and run approve-evidence.sh themselves."
  [[ $path_cmd =~ $SHELL_START$PATHS_record ]] && decide deny "$REASON_record"

  # Only the top level (the orchestrator) runs the auto run's router. A call
  # from a subagent carries agentId; a stage agent running next-stage.sh could
  # approve a stop itself or upset the stall detection. Any spelling counts: the
  # name is matched with quotes and backslashes taken out, a glob (next-st*.sh)
  # or a variable holding it (x=next-stage) too. A subagent's command that names
  # it is denied unless every part of it only reads (cat, grep, git diff ...)
  # and nothing is substituted into it.
  if [ -n "$subagent" ]; then
    bare="${cmd//[\"\'\\]/}"
    router_name='(^|[/[:space:]=<>(`])next-(stage|s[a-z]*[*?[])'
    if [[ $bare =~ $router_name ]]; then
      reader='^[[:space:]]*(cat|head|tail|less|more|grep|egrep|fgrep|wc|ls|stat|file|nl|diff|git[[:space:]]+(diff|log|show|blame|grep|status))([[:space:]]|$)'
      substituted='\$\(|`|[<>]\('
      only_reads=true
      [[ $cmd =~ $substituted ]] && only_reads=false
      split_parts "$cmd"
      while IFS= read -r seg; do
        [[ -z "${seg//[[:space:]]/}" || $seg =~ $reader ]] || only_reads=false
      done <<<"$REPLY"
      $only_reads ||
        decide deny "Only the orchestrator runs next-stage.sh. Finish your stage, end with your **Result:** line and return. (Reading it with cat, grep or git diff is fine.)"
    fi
  fi

  # `source` or `.` in command position (start, after ;&|({ or a backtick, or
  # just inside a quote as in bash -c '. x'), then a path into scripts/agent/.
  # Sourcing gives the shell functions like gate_record_run, approval_write and
  # state_set_review, which write records and task state without the scripts' checks.
  sourced="(^|[;&|({\`\"'])[[:space:]]*(source|\.)[[:space:]]+[\"']?([^[:space:];&|]*/)?scripts/agent/"
  [[ $cmd =~ $sourced ]] &&
    decide deny "Run the pipeline's scripts (scripts/agent/<name>.sh); don't source them. Their functions write the verified commit, evidence approvals and task state, which only the scripts and the user may change."

  # Shell writes to pipeline config and task state. A redirect is checked on
  # the whole command: splitting at ; | & first would cut the clobber `>|` and
  # the csh-style `>&word` in half. It may put a relative prefix (./, ../,
  # dir/) before the path. A writer command (cp, rm, sed -i ...) is checked per
  # segment, so `rm -rf x && scripts/agent/...` is fine.
  for kind in config state; do
    v="PATHS_$kind"; r="REASON_$kind"
    redirect=">[|&]?[[:space:]]*[\"']?([^[:space:];&|]*/)?${!v}"
    [[ $path_cmd =~ $redirect ]] && decide deny "${!r}"
  done
  split_parts "$path_cmd"; path_parts="$REPLY"
  writer='(^|[[:space:]/(])(tee|cp|mv|rm|rmdir|ln|chmod|chown|truncate|install|dd|patch|unlink|shred|rsync|sed[[:space:]]+([^|;&]*[[:space:]])?(-[a-zA-Z]*i|--in-place)|perl[[:space:]]+-[a-zA-Z]*i|(python[0-9.]*|node|ruby|perl)[[:space:]]+-[a-zA-Z]*[ce]|git[[:space:]]+(checkout|restore|rm|mv|apply|stash))([[:space:]]|$)'
  while IFS= read -r seg; do
    for kind in config state; do
      v="PATHS_$kind"; r="REASON_$kind"
      [[ $seg =~ $writer ]] && [[ $seg =~ $SHELL_START${!v} ]] && decide deny "${!r}"
    done
  done <<<"$path_parts"

  [[ $path_cmd =~ $SHELL_START$PATHS_secret ]] && decide deny "$REASON_secret"
  has '(\$\{?[A-Za-z_]*(TOKEN|SECRET|PASSWORD|API_KEY)|(^|[;&|[:space:]])(printenv|env|set|export -p)([[:space:]]*($|[;&|>]))|pk_[A-Za-z0-9]{6,}|glpat-)' &&
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
    p="${p//\\//}"   # Windows paths (C:\repo\scripts\agent\x) match like any other
    squash_path "$p"; p="$REPLY"
    [[ $p =~ $PATH_START$PATHS_secret ]] && decide deny "$REASON_secret"
    if $is_edit; then
      [[ $p =~ $PATH_START$PATHS_record ]] && decide deny "$REASON_record"
      [[ $p =~ $PATH_START$PATHS_config ]] && decide deny "$REASON_config"
      [[ $p =~ $PATH_START$PATHS_state ]] && decide deny "$REASON_state"
    fi
  done <<<"$paths"
fi

decide allow
