#!/usr/bin/env bash
# Findings: the numbered items of a task's code-review.md, in both routes.
# The reviewer agent writes them (reviewer.agent.md has the templates); this is
# the only code that reads or changes them. next-stage.sh and
# post-review-thread.sh source it.
#
#   ### CR-<n> · <severity> · <category> · `<file:line>`
#   - **Problem:** …
#   - **Decision:** fix · **Route:** quick       (fields: see below)
#   - **Thread:** <id>                            (added once posted)
#
# A finding runs from its "### CR-<n>" heading to the next ## or ### heading (a
# "# " line inside it, such as a shell comment in a code block, isn't one).
# A field is "**Key:**" at the start of a "- " line, or after " · " on one. Its
# value is the first word up to the next " · ", lower case, without markdown
# marks or trailing punctuation. A placeholder reads as empty: "pending", a
# value starting with "(", or a choice list such as "post | debt | skip".
# When a field appears twice, the last one counts.
#
#   findings_list <file>               "<CR-n>␟decision␟route␟thread␟status␟replied" per finding (␟ = \037)
#   finding_heading <file> <CR-n>      "severity␟category␟location"
#   finding_body <file> <CR-n>         the finding's lines without its heading or bookkeeping lines
#   finding_set_thread <file> <CR-n> <id>   puts "- **Thread:** <id>" after its Decision line,
#                                      in place of any Thread line it had
#   findings_without_added <file>      the file without the lines added after approval
# Each returns 1, quietly, when the file or the finding isn't there; the caller
# says why.

# The headings that end a finding (an awk regex, used with $0 ~ FINDINGS_HEADING).
FINDINGS_HEADING='^###? '
# Lines that are the pipeline's bookkeeping, not part of what was found.
FINDINGS_BOOKKEEPING="Decision Route Thread Status Replied"
# Lines added after the user approved the findings: they don't change what was approved.
FINDINGS_ADDED="Thread Replied"

# _findings_keys_re <keys>: an ERE for a "- **Key:**" line of any of those keys.
_findings_keys_re() { printf '^- \\*\\*(%s):\\*\\*' "$(tr ' ' '|' <<<"$1")"; }

# _finding_block <file> <CR-n>: the finding's lines, heading first.
_finding_block() {
  [ -f "$1" ] || return 1
  awk -v h="$FINDINGS_HEADING" -v id="$2" '$0 ~ h { on = ($1 == "###" && $2 == id) } on' "$1"
}

findings_list() {
  [ -f "$1" ] || return 1
  awk '
    function val(s, key,   i, k, w) {
      if (s !~ /^- /) return "\001"
      k = "**" key ":**"
      if (index(s, "- " k) == 1) i = 1 + length("- " k)
      else if ((i = index(s, "· " k))) i += length("· " k)   # in bytes or characters alike
      else return "\001"
      s = substr(s, i); sub(/·.*/, "", s); gsub(/[*_`]/, "", s)
      sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s)
      if (s ~ /^\(/ || s ~ /\|/ || tolower(s) == "pending") return ""
      split(s, w, /[ \t]+/); w[1] = tolower(w[1]); sub(/[.,;:!]+$/, "", w[1]); return w[1]
    }
    function set(name,   v) { v = val($0, name); if (v != "\001") f[name] = v }
    function flush() { if (id != "") print id "\037" f["Decision"] "\037" f["Route"] "\037" f["Thread"] "\037" f["Status"] "\037" f["Replied"]; id = "" }
    $0 ~ h { flush(); if ($1 == "###" && $2 ~ /^CR-[0-9]+$/) { id = $2; split("", f) }; next }
    id != "" { set("Decision"); set("Route"); set("Thread"); set("Status"); set("Replied") }
    END { flush() }' h="$FINDINGS_HEADING" "$1"
}

finding_heading() {
  local h; h="$(_finding_block "$1" "$2" | head -n1)"
  [ -n "$h" ] || return 1
  awk -F' · ' '{ loc = ""; if (match($0, /`[^`]+`/)) loc = substr($0, RSTART + 1, RLENGTH - 2)
                 print $2 "\037" $3 "\037" loc }' <<<"$h"
}

finding_body() {
  local b; b="$(_finding_block "$1" "$2")"
  [ -n "$b" ] || return 1
  tail -n +2 <<<"$b" | grep -vE "$(_findings_keys_re "$FINDINGS_BOOKKEEPING")" | sed -e :a -e '/^[[:space:]]*$/{$d;N;ba' -e '}'
}

finding_set_thread() {
  [ -f "$1" ] || return 1
  local tmp="$1.tmp"
  awk -v h="$FINDINGS_HEADING" -v id="$2" -v did="$3" '
    $0 ~ h { on = ($1 == "###" && $2 == id) }
    on && /^- \*\*Thread:\*\*/ { next }   # a placeholder; posting refuses a real one
    { print }
    on && !done && /^- \*\*Decision:\*\*/ { print "- **Thread:** " did; done = 1 }
    END { exit !done }' "$1" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$1"
}

findings_without_added() {
  [ -f "$1" ] || return 1
  grep -vE "$(_findings_keys_re "$FINDINGS_ADDED")" "$1" || true
}
