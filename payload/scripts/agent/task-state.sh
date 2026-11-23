#!/usr/bin/env bash
# Task state: the scripts' record of a task in .work/<task-id>/state.env, its
# kind, branch, merge request and Duo review round. config.sh sources this;
# don't run. A task is a delivery task (start-task.sh) or an MR review
# (start-review.sh, ADR 0003), which has a ClickUp id instead of a branch and
# no Duo round.
#
# The file is data, never run as code. Readers parse its KEY=value lines, take
# the last line when a key repeats, and ignore keys they don't know, so a line
# like BASE_BRANCH=x can't override a setting and a value like $(cmd) is just text.
#
#   state_kind <task>           DELIVERY or MR_REVIEW             default DELIVERY
#   state_is_review <task>      status 0 for an MR review, 1 otherwise (also with no
#                               file); prints nothing. Use it, not state_kind, to pick
#                               a script's MR review behaviour.
#   state_branch <task>         the task's branch                 required (none in an MR review)
#   state_mr_iid <task>         the merge request's iid           required
#   state_clickup_id <task>     an MR review's ClickUp task       default empty
#   state_target_branch <task>  the branch an MR review's MR targets  default empty
#   state_adopted <task>        mr or branch for an adopted task (ADR 0004)  default empty
#   state_review_round <task>   Duo review rounds counted so far  default 0
#   state_review_seen <task>    the Duo round's seen set: "<thread>:<last note>,..."
#                               (duo-round-lib.sh). A file from before #106 has
#                               REVIEW_IDS (checksums) instead, read here too  default empty
#   state_reviewed_sha <task>   commit the reviewer last reviewed default empty
#
#   state_init <task> <branch>             create the file (no-op if it exists)
#   state_init_review <task> <iid>         the same, for an MR review
#   state_set_clickup_id <task> <id>
#   state_set_target_branch <task> <branch>
#   state_set_adopted <task> mr|branch
#   state_set_mr_iid <task> <iid>
#   state_set_review <task> <round> <seen>  the round and its seen set, always
#                                           together; drops a REVIEW_IDS
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

state_kind() { _state_optional "$1" KIND DELIVERY; }
state_is_review() { [ "$(state_kind "$1" 2>/dev/null)" = MR_REVIEW ]; }
state_branch() {
  state_is_review "$1" && { echo "$1 is an MR review: it has no branch." >&2; return 1; }
  _state_required "$1" BRANCH "No BRANCH in $(_state_name "$1"). start-task.sh writes it, so the file was changed by hand or is damaged."
}
state_mr_iid() {
  _state_required "$1" MR_IID "No MR for $1 yet (no MR_IID in $(_state_name "$1")). Run scripts/agent/create-mr.sh $1 first."
}
state_review_round() { _state_optional "$1" REVIEW_ROUND 0; }
state_review_seen()  { local v; v="$(_state_optional "$1" REVIEW_SEEN "")" || return 1; [ -n "$v" ] || v="$(_state_optional "$1" REVIEW_IDS "")" || return 1; printf '%s\n' "$v"; }
state_reviewed_sha() { _state_optional "$1" REVIEWED_SHA ""; }
state_clickup_id()   { _state_optional "$1" CLICKUP_ID ""; }
state_target_branch() { _state_optional "$1" TARGET_BRANCH ""; }
state_adopted()      { _state_optional "$1" ADOPTED ""; }   # mr | branch: an adopted task (ADR 0004)

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

# _state_drop <task> <KEY>: remove KEY's lines.
_state_drop() {
  local file tmp
  file="$(_state_file "$1")"; tmp="$file.tmp"
  { grep -v "^$2=" "$file" || true; } > "$tmp"
  mv "$tmp" "$file"
}

state_init() {
  local file; file="$(_state_file "$1")"
  [ -f "$file" ] && return 0
  _state_check "$1" TASK "$1" && _state_check "$1" BRANCH "$2" || return 1
  mkdir -p "$(dirname "$file")"
  printf 'TASK=%s\nBRANCH=%s\nREVIEW_ROUND=0\n' "$1" "$2" > "$file"
}
state_init_review() {
  local file; file="$(_state_file "$1")"
  [ -f "$file" ] && return 0
  _state_check "$1" TASK "$1" && _state_check "$1" MR_IID "$2" || return 1
  mkdir -p "$(dirname "$file")"
  printf 'TASK=%s\nKIND=MR_REVIEW\nMR_IID=%s\n' "$1" "$2" > "$file"
}
state_set_clickup_id() {
  _state_require_file "$1" && _state_check "$1" CLICKUP_ID "$2" || return 1
  _state_put "$1" CLICKUP_ID "$2"
}
state_set_target_branch() {
  _state_require_file "$1" && _state_check "$1" TARGET_BRANCH "$2" || return 1
  _state_put "$1" TARGET_BRANCH "$2"
}
state_set_adopted() {
  case "$2" in mr|branch) ;; *) echo "ADOPTED must be mr or branch, not: $2" >&2; return 1 ;; esac
  _state_require_file "$1" || return 1
  _state_put "$1" ADOPTED "$2"
}
state_set_mr_iid() {
  _state_require_file "$1" && _state_check "$1" MR_IID "$2" || return 1
  _state_put "$1" MR_IID "$2"
}
state_set_review() {
  _state_require_file "$1" && _state_check "$1" REVIEW_ROUND "$2" && _state_check "$1" REVIEW_SEEN "$3" || return 1
  _state_put "$1" REVIEW_ROUND "$2" && _state_put "$1" REVIEW_SEEN "$3" && _state_drop "$1" REVIEW_IDS
}
state_set_reviewed_sha() {
  _state_require_file "$1" && _state_check "$1" REVIEWED_SHA "$2" || return 1
  _state_put "$1" REVIEWED_SHA "$2"
}

# ---------- removed ----------
# load_state and set_state were removed in v2.0.0 (ADR 0002). These stubs stay
# so a script you changed (which --update keeps) stops at the call with a
# message, instead of running on with empty values: several pipeline scripts
# run without set -e, where "command not found" would not stop them.
_state_removed() {
  echo "$1 was removed in v2.0.0. Use the state_* functions in scripts/agent/task-state.sh (see CHANGELOG.md, v2.0.0)." >&2
  exit 1
}
load_state() { _state_removed load_state; }
set_state() { _state_removed set_state; }
