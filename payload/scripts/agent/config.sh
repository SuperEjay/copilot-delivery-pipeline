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
: "${MAX_AUTO_FIX_ROUNDS:=2}"
: "${MR_DRAFT:=true}"
: "${EVIDENCE_BASE_URL:=http://localhost:3000}"
: "${EVIDENCE_START_CMD=}"
: "${EVIDENCE_STORAGE_STATE:=}"
: "${EVIDENCE_VIEWPORT:=1440x900}"
: "${MR_REVIEW_MAX_FILES:=40}"
: "${MR_REVIEW_SKIP_PATTERN:=(^|/)(package-lock\.json|npm-shrinkwrap\.json|yarn\.lock|pnpm-lock\.yaml|bun\.lockb?|Gemfile\.lock|poetry\.lock|Cargo\.lock|composer\.lock|go\.sum)$|\.min\.(js|css)$|\.map$|\.snap$|(^|/)(dist|build|__generated__)/}"

task_dir() { echo "$WORK_DIR/$1"; }

# review_worktree <task>: the MR review's worktree (ADR 0003). It lives in the
# git folder, where test runners and linters run in the checkout can't see it.
review_worktree() {
  local gitdir; gitdir="$(cd "$REPO_ROOT" && cd "$(git rev-parse --git-common-dir)" && pwd)"
  echo "$gitdir/pipeline-reviews/$1"
}

require() {
  for bin in "$@"; do
    command -v "$bin" >/dev/null 2>&1 || { echo "Missing dependency: $bin" >&2; exit 1; }
  done
}

# The task state readers and writers (.work/<id>/state.env).
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/task-state.sh"
