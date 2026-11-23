#!/usr/bin/env bash
# Usage: start-task.sh <clickup-task-id> <short-slug>
#        start-task.sh <clickup-task-id> --branch <branch>
#        start-task.sh <clickup-task-id> --mr <iid>
# Creates (or switches to) the task branch and the .work/<task-id>/ folder.
#
# With a slug, the branch is <BRANCH_PREFIX>/<task-id>-<slug>, made from
# origin/<BASE_BRANCH>. --branch and --mr adopt work you started outside the
# pipeline (ADR 0004): the branch keeps its name and its commits, and the task
# runs the whole delivery route on top of them. --mr takes the source branch of
# your own open MR. The MR's iid is not recorded here: the shipper finds and
# updates that MR, so verify, review and evidence all run first. It writes
# adopted-commits.md (the branch's commits and changed files) for the planner,
# and with --mr adopted-mr.md (the MR's title and description) for the shipper.
#
# Refuses: uncommitted changes; a task already on another branch; a branch that
# has diverged from origin (pushes are never forced); with --mr, an MR that
# isn't yours (use /review-mr), isn't open, comes from a fork or targets a
# branch other than BASE_BRANCH. A branch behind origin/<branch> is
# fast-forwarded. One behind origin/<BASE_BRANCH> is only reported: rebasing or
# merging it stays your call.
set -euo pipefail
source "$(dirname "$0")/config.sh"

USAGE="usage: start-task.sh <clickup-task-id> <short-slug> | <clickup-task-id> --branch <branch> | <clickup-task-id> --mr <iid>"
TASK="${1:?$USAGE}"
MODE="${2:?$USAGE}"
ADOPT=""; MR=""
case "$MODE" in
  --branch) BRANCH="${3:?$USAGE}"; ADOPT=branch ;;
  --mr)     MR="${3:?$USAGE}"; ADOPT=mr
            case "$MR" in ''|*[!0-9]*) echo "The MR iid must be a number, the 142 in !142. Got: $MR" >&2; exit 1 ;; esac ;;
  -*)       echo "$USAGE" >&2; exit 1 ;;
  *)        BRANCH="$BRANCH_PREFIX/$TASK-$MODE" ;;
esac
DIR="$(task_dir "$TASK")"
MR_JSON=""
# field <jq path>: one value of the MR read for --mr, empty when missing.
field() { jq -r "$1 // empty" <<< "$MR_JSON"; }

if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  echo "You have uncommitted changes. Commit or stash them first." >&2
  exit 1
fi

if [ "$ADOPT" = mr ]; then
  require glab jq
  ME="$(glab api user | jq -r '.username // empty')" || ME=""
  [ -n "$ME" ] || { echo "Can't look up your glab user (glab api user). Check glab auth status." >&2; exit 1; }
  MR_JSON="$(glab api "projects/:id/merge_requests/$MR")" || { echo "Can't read MR !$MR (see above)." >&2; exit 1; }
  state="$(field .state)"; author="$(field .author.username)"; target="$(field .target_branch)"
  [ "$state" = opened ] || { echo "MR !$MR is $state, not open. Only an open MR can be adopted." >&2; exit 1; }
  if [ "$author" != "$ME" ]; then
    echo "MR !$MR is by $author, not you ($ME). The pipeline only fixes your own MRs. To review a teammate's, run /review-mr $MR." >&2
    exit 1
  fi
  if [ "$(field .source_project_id)" != "$(field .project_id)" ]; then
    echo "MR !$MR comes from a fork. The pipeline pushes to origin, so it can't adopt it." >&2; exit 1
  fi
  [ "$target" = "$BASE_BRANCH" ] || { echo "MR !$MR targets $target, but BASE_BRANCH is $BASE_BRANCH. Adopt only MRs into $BASE_BRANCH." >&2; exit 1; }
  BRANCH="$(field .source_branch)"
fi

if [ "$BRANCH" = "$BASE_BRANCH" ]; then
  echo "$BRANCH is the base branch (BASE_BRANCH). The pipeline never works on it directly: adopt your feature branch instead." >&2
  exit 1
fi

if [ -f "$DIR/state.env" ]; then
  have="$(state_branch "$TASK" 2>/dev/null || true)"
  if [ -n "$have" ] && [ "$have" != "$BRANCH" ]; then
    echo "Task $TASK is already on branch $have. Run /start-task with that branch, or use a new task id." >&2
    exit 1
  fi
fi

git fetch origin "$BASE_BRANCH" --quiet
if [ -z "$ADOPT" ]; then
  if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
    git switch --quiet "$BRANCH"
  else
    git switch --quiet -c "$BRANCH" "origin/$BASE_BRANCH"
  fi
else
  # ls-remote --exit-code: 0 found, 2 not on origin, anything else an error
  # (network, auth), which must not pass for "only you have this branch".
  remote=no; rc=0
  git ls-remote --exit-code --heads origin "$BRANCH" > /dev/null || rc=$?
  case "$rc" in
    0) git fetch origin "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH" --quiet; remote=yes ;;
    2) ;;
    *) echo "Can't ask origin about $BRANCH (git ls-remote exit $rc, see above). Check your connection and access, then run this again." >&2; exit 1 ;;
  esac
  if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
    if [ "$remote" = yes ]; then
      if ! git merge-base --is-ancestor "$BRANCH" "origin/$BRANCH" && ! git merge-base --is-ancestor "origin/$BRANCH" "$BRANCH"; then
        echo "Your $BRANCH and origin/$BRANCH have diverged. The pipeline never force-pushes: bring them together yourself, then run this again." >&2
        exit 1
      fi
    fi
    git switch --quiet "$BRANCH"
    if [ "$remote" = yes ] && ! git merge-base --is-ancestor "origin/$BRANCH" HEAD; then
      git merge --ff-only --quiet "origin/$BRANCH"
      echo "Fast-forwarded $BRANCH to origin/$BRANCH."
    fi
  elif [ "$remote" = yes ]; then
    git switch --quiet -c "$BRANCH" --track "origin/$BRANCH"
  else
    echo "No branch $BRANCH, here or on origin." >&2
    exit 1
  fi
fi

mkdir -p "$DIR/logs"
state_init "$TASK" "$BRANCH"
if [ -n "$ADOPT" ]; then
  state_set_adopted "$TASK" "$ADOPT"
  if [ "$ADOPT" = mr ]; then
    { echo "# $(field .title)"; echo; field .description; } > "$DIR/adopted-mr.md"
  fi
  # What the branch already has, for the planner (it can't run git).
  base="$(git merge-base HEAD "origin/$BASE_BRANCH")"
  { echo "# Adopted branch $BRANCH"; echo
    echo "Commits since it left origin/$BASE_BRANCH:"; echo; echo '~~~'; git log --oneline "$base..HEAD"; echo '~~~'; echo
    echo "Files changed:"; echo; echo '~~~'; git diff --stat "$base" HEAD; echo '~~~'
  } > "$DIR/adopted-commits.md"
  behind="$(git rev-list --count "HEAD..origin/$BASE_BRANCH")"
  if [ "$behind" -gt 0 ]; then
    echo "Note: $BRANCH is $behind commit(s) behind origin/$BASE_BRANCH. The pipeline won't rebase or merge it; do that yourself if you want it up to date."
  fi
  echo "Adopted $BRANCH for task $TASK$([ "$ADOPT" = mr ] && echo " (MR !$MR)"). Work folder: ${DIR#"$REPO_ROOT"/}"
else
  echo "Task $TASK on branch $BRANCH. Work folder: ${DIR#"$REPO_ROOT"/}"
fi
