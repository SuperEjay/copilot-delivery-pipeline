#!/usr/bin/env bash
# Usage: cleanup-task.sh <task-id | mr-<iid>> [--force] [--drop-debt]
#        cleanup-task.sh --finished
# Removes what a finished task leaves in the project (#132), once the forge says
# its MR is merged or closed:
#   merged          the local task branch (force-deleted: a squash merge makes
#                   git branch -d refuse, and the forge's "merged" is the proof)
#                   and .work/<task-id>/
#   closed          .work/<task-id>/ only. The branch may hold work you want
#                   back: the command to delete it is printed. A remote branch
#                   that's still there is pointed out, never deleted.
#   an MR review    its review worktree and .work/mr-<iid>/ (start-review.sh
#                   <iid> --done runs this)
# It never touches the remote, and never switches branches or stashes.
#
# It refuses, and changes nothing, when the MR is open, the task has no MR, glab
# can't tell the MR's state, you're on the task's branch, or the checkout has
# uncommitted changes (a delivery task). --force skips the MR check (a task you
# abandoned before it got an MR, or a review you no longer need); without a
# merged MR the branch is then kept. Agents never add --force themselves.
# Parked debt in tech-debt.md ("Status: parked") is printed and refused, so a
# decision still to make is never lost silently; --drop-debt goes ahead once
# you've copied it somewhere.
#
# --finished goes through every task in .work/: it cleans those whose MR is
# merged or closed, skips the ones it can't clean yet (and says why), and ends
# with a summary. It never forces anything.
#
# --finished --list changes nothing: one "<task> <iid> <state>" line for each task
# that has an MR, the state as the forge gives it (opened, merged, closed, locked)
# or unknown when it can't be read. doctor.sh reports from it (#140).
set -uo pipefail
source "$(dirname "$0")/config.sh"

USAGE="usage: cleanup-task.sh <task-id | mr-<iid>> [--force] [--drop-debt] | cleanup-task.sh --finished [--list]"
source "$(dirname "$0")/forge-lib.sh"

# _tasks: every task id in the work folder, one per line.
_tasks() {
  local f
  for f in "$WORK_DIR"/*/state.env; do
    [ -f "$f" ] && basename "$(dirname "$f")"
  done
  return 0
}

# clean_one <task> <force yes|no> <drop-debt yes|no>: clean one task up. Prints
# what it did, or the refusal; returns 0 cleaned, 1 refused (its reason in
# WHY), 2 still open (the MR is open or there's no MR yet).
clean_one() {
  local task="$1" force="$2" drop="$3" dir kind iid state branch wt rel
  WHY=""
  case "$task" in
    ''|.|..|*/*|-*) WHY="not a task id: '$task'"; echo "$task is not a task id." >&2; return 1 ;;
  esac
  dir="$(task_dir "$task")"; rel="${dir#"$REPO_ROOT"/}"
  if [ ! -f "$dir/state.env" ]; then
    WHY="no task"; echo "No task $task in ${WORK_DIR#"$REPO_ROOT"/}/." >&2; return 1
  fi
  kind="$(state_kind "$task")" || { WHY="unreadable state"; return 1; }
  iid="$(_state_optional "$task" MR_IID "")" || { WHY="unreadable state"; return 1; }

  state=""
  if [ "$force" != yes ]; then
    if [ -z "$iid" ]; then
      WHY="no MR yet"
      echo "$task has no MR yet, so there's nothing finished to clean up. If you abandoned it, run cleanup-task.sh $task --force (the branch is kept)." >&2
      return 2
    fi
    state="$(forge_mr_state "$iid" 2>/dev/null)" || state=""   # no glab, not logged in, no such MR
    case "$state" in
      merged|closed) ;;
      '') WHY="can't tell the MR's state"
          echo "Can't tell whether MR !$iid is merged or closed: check glab auth status. Nothing was removed." >&2; return 1 ;;
      *)  WHY="MR !$iid is $state"
          echo "MR !$iid is $state: clean $task up once it's merged or closed. Nothing was removed." >&2; return 2 ;;
    esac
  fi

  if [ "$kind" != MR_REVIEW ]; then
    branch="$(state_branch "$task")" || { WHY="unreadable state"; return 1; }
    if [ "$(git -C "$REPO_ROOT" symbolic-ref --quiet --short HEAD 2>/dev/null)" = "$branch" ]; then
      WHY="on its branch"
      echo "You're on $branch, $task's branch: switch to another branch first (git switch $BASE_BRANCH). Nothing was removed." >&2; return 1
    fi
    if [ -n "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=no)" ]; then
      WHY="uncommitted changes"
      echo "The checkout has uncommitted changes: commit or stash them first. Nothing was removed." >&2; return 1
    fi
  fi

  if [ "$drop" != yes ] && grep -qE '^- \*\*Status:\*\* parked' "$dir/tech-debt.md" 2>/dev/null; then
    WHY="parked debt in $rel/tech-debt.md"
    {
      echo "$rel/tech-debt.md still has parked debt, a decision still to make:"
      awk '/^### / { h = $0 } /^- \*\*Status:\*\* parked/ { print "  " h }' "$dir/tech-debt.md"
      echo "Copy it to where you track debt (ClickUp, say), then run cleanup-task.sh $task --drop-debt. Nothing was removed."
    } >&2
    return 1
  fi

  if [ "$kind" = MR_REVIEW ]; then
    wt="$(review_worktree "$task")"
    git -C "$REPO_ROOT" worktree prune
    if [ -e "$wt" ]; then
      [ -L "$wt/node_modules" ] && rm -f "$wt/node_modules"   # the link only, never the main checkout's
      git -C "$REPO_ROOT" worktree remove --force "$wt"
      echo "Removed the review worktree of !$iid."
    fi
  elif [ "$state" = merged ]; then
    if git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/$branch"; then
      git -C "$REPO_ROOT" branch -D "$branch" > /dev/null && echo "Deleted the branch $branch (MR !$iid is merged)."
    fi
  else
    if git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "Kept the branch $branch${iid:+ (MR !$iid is ${state:-not checked})}. When you're sure you don't need it: git branch -D $branch"
    fi
    if git -C "$REPO_ROOT" ls-remote --exit-code --heads origin "$branch" > /dev/null 2>&1; then
      echo "origin/$branch still exists. Delete it on GitLab if you're done with it."
    fi
  fi
  rm -rf "$dir"
  echo "Removed $rel."
}

case "${1:-}" in
  '') echo "$USAGE" >&2; exit 1 ;;
  --finished)
    if [ $# -eq 2 ] && [ "$2" = --list ]; then
      for t in $(_tasks); do
        iid="$(_state_optional "$t" MR_IID "" 2>/dev/null)" || continue
        [ -n "$iid" ] || continue
        state="$(forge_mr_state "$iid" 2>/dev/null)" || state=unknown
        echo "$t $iid $state"
      done
      exit 0
    fi
    [ $# -eq 1 ] || { echo "$USAGE" >&2; exit 1; }
    cleaned=(); skipped=(); open=()
    for t in $(_tasks); do
      echo "== $t"
      clean_one "$t" no no 2>&1; rc=$?
      case "$rc" in
        0) cleaned+=("$t") ;;
        2) open+=("$t") ;;
        *) skipped+=("$t ($WHY)") ;;
      esac
    done
    echo
    echo "Cleaned: ${cleaned[*]:-none}"
    if [ "${#skipped[@]}" -gt 0 ]; then for s in "${skipped[@]}"; do echo "Skipped: $s"; done; else echo "Skipped: none"; fi
    echo "Still open: ${open[*]:-none}"
    exit 0 ;;
  -*) echo "$USAGE" >&2; exit 1 ;;
esac

TASK="$1"; shift
FORCE=no; DROP=no
for a in "$@"; do
  case "$a" in
    --force) FORCE=yes ;;
    --drop-debt) DROP=yes ;;
    *) echo "$USAGE" >&2; exit 1 ;;
  esac
done
clean_one "$TASK" "$FORCE" "$DROP"
[ $? -eq 0 ]
