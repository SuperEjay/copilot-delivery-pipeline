#!/usr/bin/env bash
# Usage: start-review.sh <mr-iid> [clickup-task-id]
# Starts an MR review (ADR 0003): checks the MR is open (drafts too), creates
# .work/mr-<iid>/ and checks the MR's head out into a review worktree. Run it
# again to move the worktree to the MR's new head. The user's branch and
# uncommitted work are never touched, so a dirty checkout is fine.
# A ClickUp id given here is stored and wins over one found later; a run
# without one keeps the stored id.
#
# Dependencies: when the worktree's lockfiles match the main checkout's, its
# node_modules is a link to the main checkout's. When they differ (the MR
# changes one), INSTALL_CMD installs them fresh in the worktree, once per
# lockfile version; the log goes to .work/mr-<iid>/logs/install.log.
set -euo pipefail
source "$(dirname "$0")/config.sh"
source "$(dirname "$0")/evidence-lib.sh"   # sha256
require git glab jq

IID="${1:?usage: start-review.sh <mr-iid> [clickup-task-id]}"
CLICKUP_ID="${2:-}"
case "$IID" in
  ''|*[!0-9]*) echo "The MR iid must be a number, the 142 in !142. Got: $IID" >&2; exit 1 ;;
esac
TASK="mr-$IID"
DIR="$(task_dir "$TASK")"
WT="$(review_worktree "$TASK")"

if ! MR_JSON="$(glab api "projects/:id/merge_requests/$IID" 2>&1)"; then
  echo "Could not read MR !$IID with glab:" >&2
  printf '%s\n' "$MR_JSON" >&2
  exit 1
fi
MR_STATE="$(jq -r '.state // empty' <<<"$MR_JSON")"
case "$MR_STATE" in
  opened) ;;
  merged|closed) echo "MR !$IID is $MR_STATE: there's nothing to review." >&2; exit 1 ;;
  *) echo "MR !$IID is ${MR_STATE:-in an unknown state}: only open MRs (drafts too) can be reviewed." >&2; exit 1 ;;
esac

TARGET="$(jq -r '.target_branch // empty' <<<"$MR_JSON")"
[ -n "$TARGET" ] || { echo "glab gave no target branch for MR !$IID." >&2; exit 1; }

# The MR's head through GitLab's own ref, so a fork MR works too. The target
# branch, fetched too, is what the router counts the MR's changes against.
git fetch --quiet origin "refs/merge-requests/$IID/head"
HEAD_SHA="$(git rev-parse FETCH_HEAD)"
git fetch --quiet origin "$TARGET"

git worktree prune
if [ -f "$WT/.git" ]; then   # a worktree has a .git file; a bare folder in .git/ would fool git -C
  git -C "$WT" checkout --quiet --detach "$HEAD_SHA"
else
  mkdir -p "$(dirname "$WT")"
  git worktree add --quiet --detach "$WT" "$HEAD_SHA"
fi

state_init_review "$TASK" "$IID"
# The MR's details and commit messages, where the requirements agent looks
# for the ClickUp task (ADR 0003): branch, title and description, then commits.
COMMITS_JSON="$(glab api --paginate "projects/:id/merge_requests/$IID/commits?per_page=100" | jq -s 'add // []')"
jq --argjson commits "$COMMITS_JSON" '{iid, title, description, source_branch, target_branch, web_url,
    author: .author.username, draft: (.draft // false),
    commits: [ $commits[] | {id, title, message} ]}' <<<"$MR_JSON" > "$DIR/mr.json"
state_set_target_branch "$TASK" "$TARGET"
[ -z "$CLICKUP_ID" ] || state_set_clickup_id "$TASK" "$CLICKUP_ID"

# ---------- dependencies ----------
LOCKFILES="package-lock.json npm-shrinkwrap.json yarn.lock pnpm-lock.yaml bun.lock bun.lockb"
# _locks <dir>: one checksum over the lockfiles in <dir> (a missing one counts too).
_locks() {
  local f
  for f in $LOCKFILES; do echo "== $f"; if [ -f "$1/$f" ]; then cat "$1/$f"; fi; done | sha256 /dev/stdin | cut -c1-16
}
STAMP="$DIR/installed-lock"   # the lockfiles' checksum at the last install
mkdir -p "$DIR/logs"
WT_LOCKS="$(_locks "$WT")"
if [ "$WT_LOCKS" = "$(_locks "$REPO_ROOT")" ]; then
  rm -f "$STAMP"
  if [ -d "$REPO_ROOT/node_modules" ]; then
    [ -L "$WT/node_modules" ] || rm -rf "$WT/node_modules"
    ln -sfn "$REPO_ROOT/node_modules" "$WT/node_modules"
    DEPS="linked from the main checkout"
  else
    DEPS="none (the main checkout has no node_modules)"
  fi
elif [ -z "$INSTALL_CMD" ]; then
  DEPS="not installed (the MR changes a lockfile and INSTALL_CMD is empty)"
elif [ "$(cat "$STAMP" 2>/dev/null)" = "$WT_LOCKS" ]; then
  DEPS="installed (unchanged since the last run)"
else
  [ -L "$WT/node_modules" ] && rm -f "$WT/node_modules"
  LOG="$DIR/logs/install.log"
  if ! (cd "$WT" && CI=1 bash -c "$INSTALL_CMD") > "$LOG" 2>&1; then
    rm -f "$STAMP"
    echo "The MR changes a lockfile, and INSTALL_CMD failed in the review worktree. See ${LOG#"$REPO_ROOT"/}." >&2
    tail -n "$FAIL_TAIL_LINES" "$LOG" | sed 's/^/      /' >&2
    exit 1
  fi
  echo "$WT_LOCKS" > "$STAMP"
  DEPS="installed with INSTALL_CMD (the MR changes a lockfile)"
fi

DRAFT=""; [ "$(jq -r '.draft // false' <<<"$MR_JSON")" = true ] && DRAFT=" (draft)"
echo "MR !$IID$DRAFT at ${HEAD_SHA:0:12}. Review worktree: $WT. Work folder: ${DIR#"$REPO_ROOT"/}"
echo "Dependencies: $DEPS"
