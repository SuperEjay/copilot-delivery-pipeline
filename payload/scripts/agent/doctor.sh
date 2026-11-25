#!/usr/bin/env bash
# Checks this project's pipeline setup and changes nothing (ADR 0002).
# Usage: scripts/agent/doctor.sh      (from anywhere in the project)
#
# One line per check: PASS, WARN (works, but something's missing or unknown),
# FAIL (fix it before you run the pipeline) or INFO (to check by hand). Exits 1
# if any check FAILs. Run it after install.sh (which runs it at the end), after
# changing your shell profile or .agent.env, or when a teammate's setup acts up.
#
# It never writes a project file and never prints a secret: the guard test runs
# in a temporary directory, and the ClickUp token is only tested, not shown.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "FAIL  not inside a git repository"; exit 1; }
cd "$REPO_ROOT"
MIN_CODE="1.106"
failed=0
result() {   # result <PASS|WARN|FAIL|INFO> <message>
  printf '%-5s %s\n' "$1" "$2"
  [ "$1" = FAIL ] && failed=1
  return 0
}
has() { command -v "$1" >/dev/null 2>&1; }

# ---------- platform ----------
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*) result FAIL "Windows with Git Bash is unsupported, and the hook guard may not run there: use WSL (see the README)" ;;
esac

# ---------- tools ----------
for t in git curl jq glab node npx; do
  if has "$t"; then result PASS "$t"; else result FAIL "$t is missing (see the README's Requirements)"; fi
done
for t in pdftotext pandoc; do
  has "$t" && result PASS "$t (optional)" || result WARN "$t (optional) not found: ClickUp PDF and Word attachments won't be converted to text"
done
[ -x node_modules/.bin/jscpd ] && result PASS "jscpd (optional)" || result WARN "jscpd (optional) not in this project: the reviewer gets no duplication signals"

# ---------- GitLab login ----------
if has glab; then
  if glab auth status >/dev/null 2>&1; then result PASS "glab is logged in"
  else result FAIL "glab isn't logged in: run glab auth login (add --hostname for a self-managed GitLab)"; fi
fi

# ---------- the ClickUp token: exported, never in a file ----------
token="${CLICKUP_API_TOKEN:-}"
if [ -n "$token" ]; then result PASS "CLICKUP_API_TOKEN is exported"
else result FAIL "CLICKUP_API_TOKEN isn't exported: add export CLICKUP_API_TOKEN=\"pk_...\" to your shell profile and open a new terminal"; fi
if [ -f .agent.env ] && grep -qE '^[[:space:]]*(export[[:space:]]+)?CLICKUP_API_TOKEN=' .agent.env; then
  result FAIL "CLICKUP_API_TOKEN is set in .agent.env, which the agents can read: move it to your shell profile"
fi
if [ -n "$token" ]; then
  in_files="$(git grep -lF -e "$token" 2>/dev/null | tr '\n' ' ')"
  [ -n "$in_files" ] && result FAIL "CLICKUP_API_TOKEN's value is in a tracked file: ${in_files% }. Remove it and create a new token in ClickUp"
fi
unset token

# ---------- settings ----------
if [ ! -f .agent.env ]; then
  result FAIL "no .agent.env: copy .agent.env.example to .agent.env and fill in your project's values"
elif [ -f .agent.env.example ]; then
  unset_keys="$(sed -nE 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=.*/\2/p' .agent.env.example | while read -r k; do
    grep -qE "^[[:space:]]*(export[[:space:]]+)?$k=" .agent.env || printf '%s ' "$k"; done)"
  if [ -n "$unset_keys" ]; then result WARN ".agent.env doesn't set: ${unset_keys% } (defaults apply; copy any you want from .agent.env.example)"
  else result PASS ".agent.env sets every setting in .agent.env.example"; fi
fi

# ---------- e2e without Playwright (ADR 0005) ----------
has_playwright=false
grep -qs '"@playwright/test"' package.json && has_playwright=true
e2e="$(bash -c 'source scripts/agent/config.sh >/dev/null 2>&1; printf "%s" "$E2E_CMD"' 2>/dev/null)"
if [ -z "$e2e" ]; then
  result INFO "e2e: skipped (E2E_CMD is empty, or package.json has no @playwright/test). run-checks.sh prints SKIP and the verifier records it as a gap"
elif ! $has_playwright && printf '%s' "$e2e" | grep -q 'playwright'; then
  result WARN "E2E_CMD runs Playwright, but package.json has no @playwright/test, so e2e will fail and block the push. Remove the E2E_CMD line from .agent.env, or set E2E_CMD= to skip e2e"
fi

# ---------- line endings ----------
crlf="$(find scripts/agent -name '*.sh' -type f 2>/dev/null | sort | while read -r f; do
  grep -q $'\r' "$f" && printf '%s ' "$f"; done)"
if [ -n "$crlf" ]; then
  result FAIL "CRLF line endings, which bash can't run: ${crlf% }. Add '*.sh text eol=lf' to .gitattributes, then check the files out again"
else
  result PASS "no CRLF line endings in scripts/agent/"
fi

# ---------- the hook guard ----------
GUARD="$REPO_ROOT/scripts/agent/hooks/pre-tool-guard.sh"
if [ "${PIPELINE_GUARD:-on}" = off ]; then
  result FAIL "hook guard: PIPELINE_GUARD=off in this shell switches it off. Unset it and restart VS Code"
elif [ ! -x "$GUARD" ]; then
  result FAIL "hook guard: $GUARD is missing or not executable. Run install.sh --update"
elif ! has jq; then
  result FAIL "hook guard: can't test it without jq"
else
  # In a temporary directory: the guard logs denials to .work/hooks.log there.
  tmp="$(mktemp -d)"
  d="$(cd "$tmp" && jq -n --arg c "$tmp" '{toolName:"bash",toolArgs:{command:"git push origin main"},cwd:$c}' \
       | "$GUARD" 2>/dev/null | jq -r '.permissionDecision // "allow"' 2>/dev/null)"
  rm -rf "$tmp"
  if [ "$d" = deny ]; then result PASS "hook guard works (a test 'git push' was blocked)"
  else result FAIL "hook guard: a test 'git push' got '${d:-no answer}' instead of deny"; fi
fi

# ---------- VS Code ----------
# version_ge <a> <b>: a >= b, both X.Y[.Z].
version_ge() {
  local a1 a2 b1 b2
  a1="${1%%.*}"; a2="${1#*.}"; a2="${a2%%.*}"; b1="${2%%.*}"; b2="${2#*.}"; b2="${b2%%.*}"
  [ "$a1" -gt "$b1" ] || { [ "$a1" -eq "$b1" ] && [ "$a2" -ge "$b2" ]; }
}
code_version="$(has code && code --version 2>/dev/null | head -n1 | tr -d '\r')"
if printf '%s' "$code_version" | grep -qE '^[0-9]+\.[0-9]+(\.[0-9]+)?$'; then
  if version_ge "$code_version" "$MIN_CODE"; then result PASS "VS Code $code_version"
  else result FAIL "VS Code $code_version is older than $MIN_CODE: update it (agents, skills and hooks need $MIN_CODE+)"; fi
else
  result WARN "can't tell the VS Code version (no code on PATH): it needs $MIN_CODE or later"
fi

# ---------- finished tasks to clean up (ADR 0003, #132) ----------
# A task's branch, work folder and (in an MR review) review worktree stay until
# /cleanup removes them, once its MR is merged or closed. Only asks GitLab when
# glab is logged in. A task with no MR yet isn't finished.
work="$(bash -c 'source scripts/agent/config.sh >/dev/null 2>&1; printf "%s" "$WORK_DIR"' 2>/dev/null)"
finished_tasks=()
for f in "${work:-.work}"/*/state.env; do
  [ -f "$f" ] || continue
  iid="$(sed -n 's/^MR_IID=\([0-9][0-9]*\)$/\1/p' "$f" | tail -1)"
  [ -n "$iid" ] && finished_tasks+=("$(basename "$(dirname "$f")") $iid")
done
if [ "${#finished_tasks[@]}" -gt 0 ]; then
  if has glab && glab auth status >/dev/null 2>&1; then
    source "$(dirname "$0")/forge-lib.sh"
    for entry in "${finished_tasks[@]}"; do
      task="${entry% *}"; iid="${entry#* }"
      st=""; line="$(forge_mr "$iid" 2>/dev/null)" && IFS=$'\037' read -r _ st _ <<<"$line"
      case "$st" in
        merged|closed) result WARN "$task is finished: MR !$iid is $st. Run /cleanup $task to remove its branch, work folder or review worktree" ;;
        opened|locked) ;;
        *) result INFO "can't tell whether MR !$iid ($task) is finished: if it's merged or closed, run /cleanup $task" ;;
      esac
    done
  else
    result INFO "tasks with an MR: ${#finished_tasks[@]}. Without glab logged in, it can't tell which are finished; clean one up with /cleanup <task-id>"
  fi
fi

# ---------- to check by hand ----------
result INFO "pinned models: a script can't check them. In an auto run, pick a model other than Auto, then check each stage's model in the chat's subagent details (see Pinned models in docs/agent-pipeline.md)"

exit "$failed"
