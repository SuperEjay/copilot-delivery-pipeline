#!/usr/bin/env bash
# ClickUp REST API helper. Replaces the ClickUp MCP server where MCP is blocked.
#
#   clickup.sh fetch   <task-id>             Pull the task into .work/<task-id>/clickup/
#   clickup.sh comment <task-id> <file>      Post the file's text as a task comment
#   clickup.sh status  <task-id> ["<status>"] Move the task to a status (default: CLICKUP_REVIEW_STATUS)
#   clickup.sh attach  <task-id> <file>...   Upload files as task attachments#
# Needs CLICKUP_API_TOKEN (personal token, "pk_...") in the environment, and
# CLICKUP_TEAM_ID (your Workspace ID) for custom task IDs and ClickUp Docs.
# The token is only ever sent in a header. This script never prints it.
set -euo pipefail
source "$(dirname "$0")/config.sh"
require curl jq

: "${CLICKUP_API_BASE:=https://api.clickup.com/api}"
: "${CLICKUP_TEAM_ID:=}"
: "${CLICKUP_MAX_SUBTASKS:=20}"
: "${CLICKUP_DOWNLOAD_ATTACHMENTS:=true}"
if [ -z "${CLICKUP_API_TOKEN:-}" ]; then
  echo "CLICKUP_API_TOKEN is not set. See README-agent-pipeline.md, step 6." >&2
  exit 1
fi

CMD="${1:?usage: clickup.sh fetch|comment|status <task-id> ...}"
TASK="${2:?task id}"

# api METHOD PATH [JSON_BODY]: prints the response body, fails on HTTP >= 400
api() {
  local method="$1" path="$2" body="${3:-}" out code
  local args=(-sS -X "$method" -H "Authorization: $CLICKUP_API_TOKEN"
              -H "Accept: application/json" -w $'\n%{http_code}')
  if [ -n "$body" ]; then args+=(-H "Content-Type: application/json" --data "$body"); fi
  out="$(curl "${args[@]}" "$CLICKUP_API_BASE$path")"
  code="${out##*$'\n'}"; out="${out%$'\n'*}"
  if [ "$code" -ge 400 ] 2>/dev/null || [ -z "$code" ]; then
    echo "ClickUp API $method $path failed (HTTP ${code:-none}): $(printf '%s' "$out" | head -c 300)" >&2
    return 1
  fi
  printf '%s' "$out"
}

# Custom task IDs (e.g. DEV-123) need custom_task_ids=true&team_id=...
id_query() {
  if [[ "$1" =~ ^[A-Za-z]+-[0-9]+$ ]]; then
    [ -n "$CLICKUP_TEAM_ID" ] || { echo "Custom task ID $1 needs CLICKUP_TEAM_ID." >&2; exit 1; }
    echo "custom_task_ids=true&team_id=$CLICKUP_TEAM_ID"
  fi
}

# Resolve whatever id the user gave to ClickUp's internal task id.
real_id() {
  local q; q="$(id_query "$1")"
  api GET "/v2/task/$1?${q}" | jq -r '.id'
}

fetch() {
  local dir out q task tid
  dir="$(task_dir "$TASK")/clickup"
  mkdir -p "$dir/attachments" "$dir/docs"
  out="$dir/task.md"
  q="$(id_query "$TASK")"

  task="$(api GET "/v2/task/$TASK?include_subtasks=true&include_markdown_description=true${q:+&$q}")"
  printf '%s' "$task" > "$dir/task.json"
  tid="$(jq -r '.id' <<<"$task")"

  # --- header, description, custom fields, checklists
  jq -r '
    def ms2date: if . == null or . == "" then "-" else ((tonumber / 1000) | strftime("%Y-%m-%d")) end;
    def cfval:
      if .value == null or .value == "" then empty
      elif .type == "drop_down" then (.value as $v | ([.type_config.options[]? | select(.orderindex == $v or .id == $v) | .name] | first) // ($v | tostring))
      elif .type == "labels" then ([.value[] as $v | .type_config.options[]? | select(.id == $v) | (.label // .name)] | join(", "))
      elif .type == "date" then (.value | ms2date)
      elif (.value | type) == "array" then (.value | map(if type == "object" then (.username // .name // .title // tostring) else tostring end) | join(", "))
      elif (.value | type) == "object" then (.value | tostring)
      else (.value | tostring) end;
    "# \(.name)",
    "",
    "- URL: \(.url)",
    "- Status: \(.status.status // "-")  ·  Priority: \(.priority.priority // "-")  ·  Due: \(.due_date | ms2date)",
    "- Assignees: \([.assignees[]?.username] | join(", ") | if . == "" then "-" else . end)",
    "- Tags: \([.tags[]?.name] | join(", ") | if . == "" then "-" else . end)",
    "",
    "## Description",
    "",
    ((.markdown_description // .text_content // "") | if . == "" then "_(empty)_" else . end),
    "",
    ( [ .custom_fields[]? | {name, v: cfval} | select(.v != null and .v != "") ] as $cf
      | if ($cf | length) > 0 then ("## Custom fields", "", ($cf[] | "- \(.name): \(.v)"), "") else empty end ),
    ( if ((.checklists // []) | length) > 0 then
        ("## Checklists", "",
         (.checklists[] | "### \(.name)", (.items[]? | "- [\(if .resolved then "x" else " " end)] \(.name)"), ""))
      else empty end )
  ' <<<"$task" > "$out"

  # --- subtasks (with their own descriptions, which often hold requirements)
  local subs n=0
  subs="$(jq -r '.subtasks[]?.id' <<<"$task")"
  if [ -n "$subs" ]; then
    printf '## Subtasks\n\n' >> "$out"
    while read -r sid; do
      n=$((n + 1))
      if [ "$n" -gt "$CLICKUP_MAX_SUBTASKS" ]; then
        echo "- _(more subtasks not fetched; raise CLICKUP_MAX_SUBTASKS)_" >> "$out"; break
      fi
      api GET "/v2/task/$sid?include_markdown_description=true" | jq -r '
        "### [\(.status.status // "-")] \(.name) (\(.id))",
        ((.markdown_description // .text_content // "") | if . == "" then "_(no description)_" else . end),
        ""' >> "$out"
    done <<<"$subs"
  fi

  # --- attachments
  local count
  count="$(jq '(.attachments // []) | length' <<<"$task")"
  if [ "$count" -gt 0 ]; then
    printf '## Attachments\n\n' >> "$out"
    jq -r '.attachments[] | [.id, (.title // "file"), (.url // "")] | @tsv' <<<"$task" |
    while IFS=$'\t' read -r aid title url; do
      local safe file
      safe="$(printf '%s' "$title" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-80)"
      file="$dir/attachments/${aid}-${safe}"
      if [ "$CLICKUP_DOWNLOAD_ATTACHMENTS" = "true" ] && [ -n "$url" ] && curl -sSfL -o "$file" "$url"; then
        local note="" lower
        lower="$(printf '%s' "$file" | tr '[:upper:]' '[:lower:]')"   # bash 3.2 (macOS) safe
        case "$lower" in
          *.pdf)  command -v pdftotext >/dev/null && pdftotext -layout "$file" "$file.txt" 2>/dev/null && note=" (text: ${file#"$dir"/}.txt)" ;;
          *.docx) command -v pandoc >/dev/null && pandoc -t gfm "$file" -o "$file.md" 2>/dev/null && note=" (text: ${file#"$dir"/}.md)" ;;
        esac
        echo "- $title → \`${file#"$dir"/}\`$note" >> "$out"
      else
        echo "- $title → $url (not downloaded)" >> "$out"
      fi
    done
    echo >> "$out"
  fi

  # --- comments, oldest first, with threaded replies (the API pages 25 at a time, newest first)
  local all='[]' page start="" start_id=""
  while :; do
    page="$(api GET "/v2/task/$tid/comment${start:+?start=$start&start_id=$start_id}")"
    all="$(jq -s '.[0] + (.[1].comments // [])' <(printf '%s' "$all") <(printf '%s' "$page"))"
    [ "$(jq '(.comments // []) | length' <<<"$page")" -ge 25 ] || break
    start="$(jq -r '.comments[-1].date' <<<"$page")"
    start_id="$(jq -r '.comments[-1].id' <<<"$page")"
  done
  printf '%s' "$all" > "$dir/comments.json"

  if [ "$(jq 'length' <<<"$all")" -gt 0 ]; then
    printf '## Comments (oldest first)\n\n' >> "$out"
    jq -r 'reverse[] | [.id, (.reply_count // 0 | tostring)] | @tsv' <<<"$all" |
    while IFS=$'\t' read -r cid replies; do
      jq -r --arg id "$cid" '.[] | select(.id == $id)
        | "**\(.user.username // "?")** (\((.date | tonumber / 1000) | strftime("%Y-%m-%d"))): \(.comment_text // "" | gsub("\\s+$"; ""))"' <<<"$all" >> "$out"
      if [ "$replies" != "0" ]; then
        api GET "/v2/comment/$cid/reply" | jq -r '(.comments // []) | reverse[]
          | "  ↳ **\(.user.username // "?")**: \(.comment_text // "" | gsub("\\s+$"; "") | gsub("\n"; "\n    "))"' >> "$out"
      fi
      echo >> "$out"
    done
  fi

  # --- linked ClickUp Docs (URLs like app.clickup.com/<ws>/v/dc/<doc-id>/...)
  local docs
  docs="$( { jq -r '.markdown_description // .text_content // ""' <<<"$task"; jq -r '.[].comment_text // ""' <<<"$all"; } \
           | grep -oE '/v/dc/[A-Za-z0-9_-]+' | sed 's#/v/dc/##' | sort -u || true)"
  if [ -n "$docs" ]; then
    printf '## Linked ClickUp Docs\n\n' >> "$out"
    if [ -z "$CLICKUP_TEAM_ID" ]; then
      echo "- _(found linked Docs but CLICKUP_TEAM_ID is not set, so they weren't fetched)_" >> "$out"
    else
      while read -r did; do
        if api GET "/v3/workspaces/$CLICKUP_TEAM_ID/docs/$did/pages?max_page_depth=-1&content_format=text%2Fmd" \
           | jq -r '
               def walk_pages(d): .[] | ("#" * (d + 1) + " " + (.name // "Untitled")), "", (.content // ""), "", ((.pages // []) | walk_pages(d + 1));
               (if type == "array" then . else (.pages // []) end) | walk_pages(0)' > "$dir/docs/$did.md"; then
          echo "- Doc $did → \`docs/$did.md\`" >> "$out"
        else
          echo "- Doc $did → could not fetch (no access?)" >> "$out"
        fi
      done <<<"$docs"
    fi
  fi

  echo "Fetched $TASK → ${out#"$REPO_ROOT"/} ($(wc -l < "$out" | tr -d ' ') lines)"
}

comment() {
  local file="${3:?message file}" tid body
  [ -s "$file" ] || { echo "Message file is empty or missing: $file" >&2; exit 1; }
  tid="$(real_id "$TASK")"
  body="$(jq -n --rawfile t "$file" '{comment_text: $t, notify_all: false}')"
  api POST "/v2/task/$tid/comment" "$body" >/dev/null
  echo "Commented on $TASK"
}

status() {
  local st="${3:-${CLICKUP_REVIEW_STATUS:-}}" tid
  [ -n "$st" ] || { echo "No status given and CLICKUP_REVIEW_STATUS is not set: leaving the status alone."; return 0; }
  tid="$(real_id "$TASK")"
  api PUT "/v2/task/$tid" "$(jq -n --arg s "$st" '{status: $s}')" >/dev/null
  echo "Moved $TASK to \"$st\""
}

attach() {
  shift 2
  [ $# -gt 0 ] || { echo "usage: clickup.sh attach <task-id> <file>..." >&2; exit 2; }
  local tid f out code n=0
  tid="$(real_id "$TASK")"
  for f in "$@"; do
    [ -f "$f" ] || { echo "Not a file: $f" >&2; exit 1; }
    out="$(curl -sS -X POST -H "Authorization: $CLICKUP_API_TOKEN" -H "Accept: application/json" \
             -F "attachment=@$f" -w $'\n%{http_code}' "$CLICKUP_API_BASE/v2/task/$tid/attachment")"
    code="${out##*$'\n'}"
    if [ -z "$code" ] || [ "$code" -ge 400 ] 2>/dev/null; then
      echo "Upload failed for $(basename "$f") (HTTP ${code:-none}): $(printf '%s' "${out%$'\n'*}" | head -c 300)" >&2
      exit 1
    fi
    n=$((n + 1)); echo "  uploaded $(basename "$f")"
  done
  echo "Attached $n file(s) to $TASK"
}

case "$CMD" in
  fetch)   fetch ;;
  comment) comment "$@" ;;
  status)  status "$@" ;;
  attach)  attach "$@" ;;
  *) echo "Unknown command: $CMD" >&2; exit 2 ;;
esac
