#!/usr/bin/env bash
# Shared settings for the agent pipeline scripts. Source this file; don't run it.
# Override any value in .agent.env at the repo root (see .agent.env.example).

REPO_ROOT="$(git rev-parse --show-toplevel)"
if [ -f "$REPO_ROOT/.agent.env" ]; then
  # shellcheck disable=SC1091
  source "$REPO_ROOT/.agent.env"
fi

: "${BASE_BRANCH:=main}"
: "${BRANCH_PREFIX:=feature}"
: "${WORK_DIR:=$REPO_ROOT/.work}"
: "${LINT_CMD=npm run lint --silent}"
: "${TYPECHECK_CMD=npx tsc --noEmit}"
: "${UNIT_CMD=npm run test:unit --silent}"
: "${INTEGRATION_CMD=npm run test:integration --silent}"
: "${E2E_CMD=npx playwright test --reporter=line}"
: "${FAIL_TAIL_LINES:=40}"
: "${DUO_USERNAMES:=}"
: "${MAX_REVIEW_ROUNDS:=3}"
: "${MR_DRAFT:=true}"
: "${EVIDENCE_BASE_URL:=http://localhost:3000}"
: "${EVIDENCE_START_CMD=}"
: "${EVIDENCE_STORAGE_STATE:=}"
: "${EVIDENCE_VIEWPORT:=1440x900}"

task_dir() { echo "$WORK_DIR/$1"; }

# The commit that last passed `run-checks.sh <task> all` on a clean tree.
verified_head() { local f; f="$(task_dir "$1")/verified-head"; [ -f "$f" ] && cat "$f"; return 0; }

# Exit unless HEAD is exactly the verified commit, so nothing unverified ships.
require_verified_head() {
  local v head
  v="$(verified_head "$1")"; head="$(git rev-parse HEAD)"
  if [ -z "$v" ]; then
    echo "No verified commit for $1. The verifier must run run-checks.sh $1 all on the final code." >&2; exit 1
  fi
  if [ "$v" != "$head" ]; then
    echo "HEAD $(git rev-parse --short HEAD) is not the verified commit ${v:0:7}: $(git rev-list --count "$v..HEAD" 2>/dev/null || echo some) commit(s) since. Re-verify before pushing." >&2
    exit 1
  fi
}

require() {
  for bin in "$@"; do
    command -v "$bin" >/dev/null 2>&1 || { echo "Missing dependency: $bin" >&2; exit 1; }
  done
}

load_state() {
  local file
  file="$(task_dir "$1")/state.env"
  [ -f "$file" ] || { echo "No $file. Run scripts/agent/start-task.sh first." >&2; exit 1; }
  # shellcheck disable=SC1090
  source "$file"
}

# Set KEY=VALUE in a task's state.env (portable: no sed -i).
set_state() {
  local file tmp
  file="$(task_dir "$1")/state.env"; tmp="$file.tmp"
  grep -v "^$2=" "$file" > "$tmp" || true
  echo "$2=$3" >> "$tmp"
  mv "$tmp" "$file"
}
