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
  local json
  json="$(_forge_mr_json "$1")" || return 1
  jq -r --arg us "$FORGE_US" '
      [ .iid, .state, .author.username, .source_branch, .target_branch,
        (if .source_project_id == .project_id then "no" else "yes" end),
        .diff_refs.head_sha, .diff_refs.base_sha, .diff_refs.start_sha ]
      | map(. // "" | tostring) | join($us)' <<<"$json"
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
