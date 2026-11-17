#!/usr/bin/env bash
# Usage: run-checks.sh <task-id> [fast|all|lint|types|unit|integration|e2e]...
#   fast = lint types unit (the default)    all = lint types unit integration e2e
#
# When a run covers every check, passes, and the tree has no uncommitted
# changes, it records HEAD in .work/<task-id>/verified-head. create-mr.sh and
# push-branch.sh only push that exact commit. A failing full run clears it.
#
# The full output of each check goes to .work/<task-id>/logs/<check>.log.
# Only one line per check plus the failing lines is printed, so an agent's
# context gets the verdict instead of thousands of lines of test output.
# Exit code: 0 all passed, 1 something failed, 2 bad arguments.
set -uo pipefail
source "$(dirname "$0")/config.sh"

TASK="${1:?usage: run-checks.sh <task-id> [checks...]}"
shift
if [ $# -eq 0 ]; then set -- fast; fi
LOGS="$(task_dir "$TASK")/logs"
mkdir -p "$LOGS"

expand() {
  case "$1" in
    fast) echo lint types unit ;;
    all)  echo lint types unit integration e2e ;;
    *)    echo "$1" ;;
  esac
}

cmd_for() {
  case "$1" in
    lint)        printf '%s' "$LINT_CMD" ;;
    types)       printf '%s' "$TYPECHECK_CMD" ;;
    unit)        printf '%s' "$UNIT_CMD" ;;
    integration) printf '%s' "$INTEGRATION_CMD" ;;
    e2e)         printf '%s' "$E2E_CMD" ;;
    *)           return 1 ;;
  esac
}

strip_ansi() { sed -E 's/\x1B\[[0-9;]*[A-Za-z]//g'; }

FAIL_PATTERN='(FAIL|✗|✕|×|[Ee]rror|AssertionError|Expected|Received|failed|panicked|Traceback)'

overall=0
ran=" "
for group in "$@"; do
  for check in $(expand "$group"); do
    ran="$ran$check "
    if ! cmd="$(cmd_for "$check")"; then
      echo "ERROR unknown check: $check"; overall=2; continue
    fi
    if [ -z "$cmd" ]; then
      echo "SKIP  $check (no command configured)"; continue
    fi

    log="$LOGS/$check.log"
    start=$(date +%s)
    (cd "$REPO_ROOT" && CI=1 NO_COLOR=1 FORCE_COLOR=0 bash -c "$cmd") 2>&1 | strip_ansi > "$log"
    code=${PIPESTATUS[0]}
    secs=$(( $(date +%s) - start ))

    if [ "$code" -eq 0 ]; then
      echo "PASS  $check (${secs}s)"
    else
      [ "$overall" -eq 0 ] && overall=1
      echo "FAIL  $check (exit $code, ${secs}s). Full log: ${log#"$REPO_ROOT"/}"
      hits="$(grep -nE "$FAIL_PATTERN" "$log" | head -n "$FAIL_TAIL_LINES")"
      if [ -n "$hits" ]; then
        printf '%s\n' "$hits" | cut -c1-240 | sed 's/^/      /'
      else
        tail -n "$FAIL_TAIL_LINES" "$log" | cut -c1-240 | sed 's/^/      /'
      fi
    fi
  done
done

full=true
for c in lint types unit integration e2e; do case "$ran" in *" $c "*) ;; *) full=false ;; esac; done
if $full; then
  marker="$(task_dir "$TASK")/verified-head"
  if [ "$overall" -ne 0 ]; then
    rm -f "$marker"
  elif [ -n "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=no)" ]; then
    rm -f "$marker"
    echo "NOTE  all checks passed, but there are uncommitted changes, so this isn't recorded as verified. Commit, then run all again."
  else
    git -C "$REPO_ROOT" rev-parse HEAD > "$marker"
    echo "VERIFIED $(git -C "$REPO_ROOT" rev-parse --short HEAD): the only commit create-mr.sh and push-branch.sh will push."
  fi
fi
exit "$overall"
