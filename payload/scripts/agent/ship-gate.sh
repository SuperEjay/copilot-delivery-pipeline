#!/usr/bin/env bash
# The ship gate: the check a commit must pass before any script pushes it.
# Source after config.sh; don't run.
#
#   gate_require <task> push      the task's branch is checked out and HEAD is
#                                 the verified commit (pushes, MR updates)
#   gate_require <task> new-mr    push, plus evidence approved at HEAD
#   gate_record_run <task> <0|1>  a full run-checks.sh run finished with this
#                                 exit status: record HEAD as the verified commit
#                                 (passed on a clean tree) or clear it
#   gate_verified <task>          the verified commit, or nothing when there is
#                                 none. The router asks this; only this file
#                                 knows where the commit is kept.
#
# gate_require exits the calling script with the reason on stderr when the
# commit may not ship (1), or when the action is unknown (2).
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/evidence-lib.sh"

_gate_marker() { echo "$(task_dir "$1")/verified-head"; }

gate_require() {
  local task="$1" action="${2:-}" v head current branch
  case "$action" in push|new-mr) ;; *) echo "Unknown ship gate action: $action (expected push or new-mr)." >&2; exit 2 ;; esac
  branch="$(state_branch "$task")" || exit 1

  current="$(git branch --show-current)"
  [ "$current" = "$branch" ] || { echo "On branch ${current:-(detached)}, expected $branch. Not pushing." >&2; exit 1; }

  v="$(gate_verified "$task")"; head="$(git rev-parse HEAD)"
  if [ -z "$v" ]; then
    echo "No verified commit for $task. The verifier must run run-checks.sh $task all on the final code." >&2; exit 1
  fi
  if [ "$v" != "$head" ]; then
    echo "HEAD $(git rev-parse --short HEAD) is not the verified commit ${v:0:7}: $(git rev-list --count "$v..HEAD" 2>/dev/null || echo some) commit(s) since. Re-verify before pushing." >&2
    exit 1
  fi

  if [ "$action" = new-mr ]; then
    approval_verify "$task" > /dev/null || exit 1
  fi
}

gate_verified() { cat "$(_gate_marker "$1")" 2>/dev/null || true; }

gate_record_run() {
  local marker; marker="$(_gate_marker "$1")"
  if [ "$2" -ne 0 ]; then
    rm -f "$marker"
  elif [ -n "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=no)" ]; then
    rm -f "$marker"
    echo "NOTE  all checks passed, but there are uncommitted changes, so this isn't recorded as verified. Commit, then run all again."
  else
    git -C "$REPO_ROOT" rev-parse HEAD > "$marker"
    echo "VERIFIED $(git -C "$REPO_ROOT" rev-parse --short HEAD): the only commit create-mr.sh and push-branch.sh will push."
  fi
}
