#!/usr/bin/env bash
# The forge (#103, GLOSSARY "Forge"): the code host the pipeline asks about
# merge requests, GitLab through glab. This is the only code that runs glab
# (tests/test-portability.sh checks it; doctor.sh's "glab auth status" is the
# one exception), so glab's argv, GitLab's API paths and its JSON field names
# live here and nowhere else. Scripts source it; it needs glab and jq.
#
# Every function lets glab's stderr through and returns non-zero when glab fails
# or GitLab's answer lacks a field it must have. It prints nothing then, so a
# caller writes its own message:   x="$(forge_mr 5)" || { echo "…" >&2; exit 1; }
#
#   forge_me                    the glab user's name
#   forge_mr <iid>              one line of \037-separated fields:
#                                 iid state author source target fork head base start
#                               fork is yes or no; head base start are the
#                               diff refs (empty when GitLab has none yet). Read it with
#                                 IFS=$'\037' read -r iid state author … <<<"$line"
#   forge_mr <iid> --with-text  the same line, then the title on one line, then
#                               the description: one call for --mr adoption
#   forge_mr_state <iid>        the MR's state alone: opened, merged, closed or
#                               locked. Non-zero with nothing on stdout when glab
#                               or jq is missing, glab fails, or <iid> isn't a number
#   forge_mr_summary <iid>      JSON: iid title description source_branch
#                               target_branch web_url author draft commits[id title message]
#   forge_discussions <iid>     JSON: every discussion, all pages, unfiltered
#   forge_eligible <purpose> <mr-line> <me> <base>
#                               no glab: whether the MR can be used for <purpose>.
#                               Returns 0, or prints a reason and returns 1:
#                                 review  open:     merged closed not-open
#                                 adopt   open, by <me>, not a fork, into <base>:
#                                         merged closed not-open not-mine fork wrong-target
#                               The first reason that applies wins. Each caller
#                               words the refusal itself.
#   forge_mr_for_branch <branch>
#                               "iid url" of the branch's open MR, or nothing
#
# Writes (the guard lets agents reach them only through create-mr.sh,
# reply-thread.sh and post-review-thread.sh, which hold the pipeline's rules):
#   forge_mr_create <branch> <target> <title> <description> [--draft]
#                               opens an MR that removes its branch when merged;
#                               prints "iid url"
#   forge_mr_update <iid> <title> <description>
#   forge_reply <iid> <discussion-id> <body>
#   forge_resolve <iid> <discussion-id>
#   forge_post_thread <iid> <json-file>
#                               a new thread from GitLab's request body (body,
#                               and a position for a diff line); prints its id

FORGE_US=$'\037'

# _forge_iid <iid>: refuses anything but a number, so it can't reach a path.
_forge_iid() {
  case "$1" in
    ''|*[!0-9]*) echo "forge: not an MR number: '$1'" >&2; return 1 ;;
  esac
}

forge_me() {
  local json user
  json="$(glab api user)" || return 1
  user="$(jq -r '.username // empty' <<<"$json")" || return 1
  [ -n "$user" ] || { echo "forge: GitLab gave no username for the glab user." >&2; return 1; }
  printf '%s\n' "$user"
}

# _forge_mr_json <iid>: GitLab's MR, with the fields every caller relies on checked.
_forge_mr_json() {
  local json missing
  _forge_iid "$1" || return 1
  json="$(glab api "projects/:id/merge_requests/$1")" || return 1
  missing="$(jq -r '[ (if (.state // "") == "" then "state" else empty end),
                      (if (.target_branch // "") == "" then "target branch" else empty end) ] | join(" and ")' <<<"$json")" || return 1
  [ -z "$missing" ] || { echo "forge: GitLab gave no $missing for MR !$1." >&2; return 1; }
  printf '%s\n' "$json"
}

forge_mr() {
  local json text=no
  case "${2:-}" in
    '') ;;
    --with-text) text=yes ;;
    *) echo "forge_mr: unknown option '$2' (--with-text)" >&2; return 2 ;;
  esac
  json="$(_forge_mr_json "$1")" || return 1
  jq -r --arg us "$FORGE_US" --arg text "$text" '
      ([ .iid, .state, .author.username, .source_branch, .target_branch,
         (if .source_project_id == .project_id then "no" else "yes" end),
         .diff_refs.head_sha, .diff_refs.base_sha, .diff_refs.start_sha ]
       | map(. // "" | tostring) | join($us)),
      (if $text == "yes" then (.title // "" | gsub("\n"; " ")), (.description // "") else empty end)' <<<"$json"
}

forge_mr_state() {
  local line st
  line="$(forge_mr "$1")" || return 1
  IFS="$FORGE_US" read -r _ st _ <<<"$line"
  printf '%s\n' "$st"
}

forge_mr_summary() {
  local json commits
  json="$(_forge_mr_json "$1")" || return 1
  commits="$(glab api --paginate "projects/:id/merge_requests/$1/commits?per_page=100")" || return 1
  commits="$(jq -s 'add // []' <<<"$commits")" || return 1
  jq --argjson commits "$commits" '{iid, title, description, source_branch, target_branch, web_url,
      author: .author.username, draft: (.draft // false),
      commits: [ $commits[] | {id, title, message} ]}' <<<"$json"
}

forge_discussions() {
  local json
  _forge_iid "$1" || return 1
  json="$(glab api --paginate "projects/:id/merge_requests/$1/discussions?per_page=100")" || return 1
  jq -s 'add // []' <<<"$json"
}

# _forge_did <discussion-id>: refuses anything but letters and digits.
_forge_did() {
  case "$1" in
    ''|*[!0-9A-Za-z]*) echo "forge: not a thread id: '$1'" >&2; return 1 ;;
  esac
}

forge_mr_for_branch() {
  local enc json
  enc="$(jq -rn --arg b "$1" '$b | @uri')" || return 1
  json="$(glab api "projects/:id/merge_requests?source_branch=$enc&state=opened")" || return 1
  jq -r '.[0] | if . == null then empty else "\(.iid) \(.web_url)" end' <<<"$json"
}

forge_mr_create() {
  local found
  local args=(--source-branch "$1" --target-branch "$2" --title "$3" --description "$4" --remove-source-branch --yes)
  [ "${5:-}" = --draft ] && args+=(--draft)
  glab mr create "${args[@]}" >/dev/null || return 1
  found="$(forge_mr_for_branch "$1")" || return 1
  [ -n "$found" ] || { echo "forge: glab reported the MR created, but GitLab has no open MR for $1." >&2; return 1; }
  printf '%s\n' "$found"
}

forge_mr_update() {
  _forge_iid "$1" || return 1
  glab api -X PUT "projects/:id/merge_requests/$1" -f "title=$2" -f "description=$3" >/dev/null
}

forge_reply() {
  _forge_iid "$1" && _forge_did "$2" || return 1
  glab api -X POST "projects/:id/merge_requests/$1/discussions/$2/notes" -f "body=$3" >/dev/null
}

forge_resolve() {
  _forge_iid "$1" && _forge_did "$2" || return 1
  glab api -X PUT "projects/:id/merge_requests/$1/discussions/$2" -f "resolved=true" >/dev/null
}

forge_post_thread() {
  local json id
  _forge_iid "$1" || return 1
  json="$(glab api -X POST "projects/:id/merge_requests/$1/discussions" -H "Content-Type: application/json" --input "$2")" || return 1
  id="$(jq -r '.id // empty' <<<"$json" 2>/dev/null)"
  [ -n "$id" ] || { echo "forge: GitLab gave no thread id for the new thread on MR !$1." >&2; return 1; }
  printf '%s\n' "$id"
}

forge_eligible() {
  local purpose="$1" line="$2" me="${3:-}" base="${4:-}" state author target fork
  IFS="$FORGE_US" read -r _ state author _ target fork _ <<<"$line"
  case "$purpose" in
    review|adopt) ;;
    *) echo "forge_eligible: unknown purpose '$purpose' (review or adopt)" >&2; return 2 ;;
  esac
  case "$state" in
    opened) ;;
    merged|closed) echo "$state"; return 1 ;;
    *) echo not-open; return 1 ;;
  esac
  [ "$purpose" = adopt ] || return 0
  [ "$author" = "$me" ] || { echo not-mine; return 1; }
  [ "$fork" = no ] || { echo fork; return 1; }
  [ "$target" = "$base" ] || { echo wrong-target; return 1; }
}
