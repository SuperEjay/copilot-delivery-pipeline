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
# A reader prints the value on stdout. A missing file, or a missing or empty
# required key, prints the reason on stderr and returns 1. Call it as
#   MR_IID="$(state_mr_iid "$TASK")" || exit 1

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
