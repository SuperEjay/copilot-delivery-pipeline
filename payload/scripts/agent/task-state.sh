#!/usr/bin/env bash
# Task state: the scripts' record of a task in .work/<task-id>/state.env, its
# branch, merge request and Duo review round. config.sh sources this; don't run.
#
# The file is data, never run as code. Readers parse its KEY=value lines, take
# the last line when a key repeats, and ignore keys they don't know, so a line
# like BASE_BRANCH=x can't override a setting and a value like $(cmd) is just text.
#
#   state_branch <task>         the task's branch                 required
#   state_mr_iid <task>         the merge request's iid           required
#   state_review_round <task>   Duo review rounds counted so far  default 0
#   state_review_ids <task>     checksum of the last thread ids   default empty
#   state_reviewed_sha <task>   commit the reviewer last reviewed default empty
#
#   state_init <task> <branch>             create the file (no-op if it exists)
#   state_set_mr_iid <task> <iid>
#   state_set_review <task> <round> <ids>  both review keys, always together
#   state_set_reviewed_sha <task> <sha>
#
# A reader prints the value on stdout. A missing file, or a missing or empty
# required key, prints the reason on stderr and returns 1. Call it as
#   MR_IID="$(state_mr_iid "$TASK")" || exit 1
# A setter returns 1 with the reason on stderr when there's no file, or when a
# value contains a newline (it would break the one-key-per-line format); it
# then writes nothing.

_state_file() { echo "$(task_dir "$1")/state.env"; }
_state_name() { local f; f="$(_state_file "$1")"; echo "${f#"$REPO_ROOT"/}"; }

_state_require_file() {
  [ -f "$(_state_file "$1")" ] && return 0
  echo "No $(_state_name "$1"). Run scripts/agent/start-task.sh first." >&2
  return 1
}

# _state_get <task> <KEY>: print KEY's value. 1 = no such key, 2 = no file.
_state_get() {
  _state_require_file "$1" || return 2
  awk -v k="$2=" 'index($0, k) == 1 { v = substr($0, length(k) + 1); found = 1 }
                  END { if (found) print v; exit !found }' "$(_state_file "$1")"
}

# _state_required <task> <KEY> <message when missing>
_state_required() {
  local v rc=0
  v="$(_state_get "$1" "$2")" || rc=$?
  [ "$rc" -eq 2 ] && return 1
  [ -n "$v" ] || { echo "$3" >&2; return 1; }
  printf '%s\n' "$v"
}

# _state_optional <task> <KEY> <default>
_state_optional() {
  local v rc=0
  v="$(_state_get "$1" "$2")" || rc=$?
  [ "$rc" -eq 2 ] && return 1
  printf '%s\n' "${v:-$3}"
}

state_branch() {
  _state_required "$1" BRANCH "No BRANCH in $(_state_name "$1"). start-task.sh writes it, so the file was changed by hand or is damaged."
}
state_mr_iid() {
  _state_required "$1" MR_IID "No MR for $1 yet (no MR_IID in $(_state_name "$1")). Run scripts/agent/create-mr.sh $1 first."
}
state_review_round() { _state_optional "$1" REVIEW_ROUND 0; }
state_review_ids()   { _state_optional "$1" REVIEW_IDS ""; }
state_reviewed_sha() { _state_optional "$1" REVIEWED_SHA ""; }

# _state_check <task> <KEY> <value>: refuse a value that would break the format.
_state_check() {
  case "$3" in *$'\n'*)
    echo "Not writing $2 to $(_state_name "$1"): the value contains a newline." >&2; return 1 ;;
  esac
}

# _state_put <task> <KEY> <value>: replace KEY's line (portable: no sed -i).
_state_put() {
  local file tmp
  file="$(_state_file "$1")"; tmp="$file.tmp"
  { grep -v "^$2=" "$file" || true; printf '%s=%s\n' "$2" "$3"; } > "$tmp"
  mv "$tmp" "$file"
}

state_init() {
  local file; file="$(_state_file "$1")"
  [ -f "$file" ] && return 0
  _state_check "$1" TASK "$1" && _state_check "$1" BRANCH "$2" || return 1
  mkdir -p "$(dirname "$file")"
  printf 'TASK=%s\nBRANCH=%s\nREVIEW_ROUND=0\n' "$1" "$2" > "$file"
}
state_set_mr_iid() {
  _state_require_file "$1" && _state_check "$1" MR_IID "$2" || return 1
  _state_put "$1" MR_IID "$2"
}
state_set_review() {
  _state_require_file "$1" && _state_check "$1" REVIEW_ROUND "$2" && _state_check "$1" REVIEW_IDS "$3" || return 1
  _state_put "$1" REVIEW_ROUND "$2" && _state_put "$1" REVIEW_IDS "$3"
}
state_set_reviewed_sha() {
  _state_require_file "$1" && _state_check "$1" REVIEWED_SHA "$2" || return 1
  _state_put "$1" REVIEWED_SHA "$2"
}

# ---------- deprecated ----------
# Kept so a script you changed, which --update keeps, still works. They parse
# the file like the readers do. Use the functions above instead; these go in a
# later release.

# load_state <task>: set TASK, BRANCH, MR_IID, REVIEW_ROUND, REVIEW_IDS and
# REVIEWED_SHA for the keys the file has. Exits the script if there's no file.
load_state() {
  local key value
  _state_require_file "$1" || exit 1
  for key in TASK BRANCH MR_IID REVIEW_ROUND REVIEW_IDS REVIEWED_SHA; do
    if value="$(_state_get "$1" "$key")"; then printf -v "$key" '%s' "$value"; fi
  done
}

# set_state <task> <KEY> <value>: exits the script if it can't write.
set_state() {
  { _state_require_file "$1" && _state_check "$1" "$2" "$3"; } || exit 1
  _state_put "$1" "$2" "$3"
}
