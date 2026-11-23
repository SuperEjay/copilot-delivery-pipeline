#!/usr/bin/env bash
# Duo rounds (#106, GLOSSARY "Duo round", "Triage"): the only code that knows a
# round's formats. fetch-duo-review.sh, next-stage.sh and apply-suggestion.sh
# source it; it needs jq and nothing else (no glab: forge-lib.sh fetches).
#
#   round_threads <discussions-json> <me> <duo-users>
#       pure: the round's threads from the forge's discussions, as JSON
#         {review: [...], seen: "<id>:<note>,...", skipped: <n>}
#       review is review.json: unresolved, resolvable threads, only by
#       <duo-users> (a comma list; empty: every author), without the ones you
#       answered (your note is the last). Each: id author file line new_line
#       head_sha body replies[author body]. seen is those threads with their
#       last note, sorted; skipped counts the ones you answered.
#   round_decide <last-round> <last-seen> <seen> <max> [--force]
#       pure: the round rule. Prints
#         same <n>          nothing new: the round stays <n> (record nothing)
#         new <n> <seen>    a thread is new or has a new note: round <n> starts
#         over <n>          round <n> would pass <max>; --force allows it
#       <last-seen> may still be REVIEW_IDS from before #106 (one cksum per
#       pair), compared the old way, so upgrading doesn't cost a round.
#   round_triage <review-triage.md>
#       "<round> <replied yes|no> <asks>": the round the file triaged, whether
#       its replies were posted, and its ASK threads. No file is "0 no 0".
#       Returns 1, saying why, when the file doesn't follow the template in
#       review-responder.agent.md: no "Round: <n>" line, no Verdict column, or
#       a verdict other than FIX, PUSH BACK or ASK.
#   round_thread <review.json> <thread-id>
#       the thread's "file\037new_line\037head_sha" on the first line, then its
#       body. Returns 1 when review.json or the thread is missing.

round_threads() {
  jq -n --argjson all "$1" --arg me "$2" --arg users "$3" '
    ($users | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))) as $u
    | [ $all[]
        | select(.notes[0].resolvable == true and (.notes[0].resolved | not))
        | select(($u | length) == 0 or (.notes[0].author.username as $a | $u | index($a)))
        | { id,
            author: .notes[0].author.username,
            file: (.notes[0].position.new_path // .notes[0].position.old_path),
            line: (.notes[0].position.new_line // .notes[0].position.old_line),
            new_line: .notes[0].position.new_line,
            head_sha: .notes[0].position.head_sha,
            body: .notes[0].body,
            replies: [ .notes[1:][] | {author: .author.username, body: (.body | .[0:400])} ],
            _answered: (.notes[-1].author.username == $me),
            _seen: "\(.id):\(.notes[-1].id)" } ] as $t
    | { review: [ $t[] | select(._answered | not) | del(._answered, ._seen) ],
        seen: ([ $t[] | select(._answered | not) | ._seen ] | sort | join(",")),
        skipped: ([ $t[] | select(._answered) ] | length) }'
}

# _round_old <pair>: a seen pair as REVIEW_IDS recorded it before #106.
_round_old() { printf '%s' "$1" | cksum | cut -d' ' -f1; }

round_decide() {
  local last="$1" last_seen="$2" seen="$3" max="$4" force="${5:-}" pair key new=no round
  case "$last$max" in ''|*[!0-9]*) echo "round_decide: the round and the limit must be numbers" >&2; return 2 ;; esac
  case "$force" in ''|--force) ;; *) echo "round_decide: unknown option '$force'" >&2; return 2 ;; esac
  for pair in ${seen//,/ }; do
    key="$pair"
    # REVIEW_IDS (before #106) holds checksums only: compare those.
    case "$last_seen" in *:*|'') ;; *) key="$(_round_old "$pair")" ;; esac
    case ",$last_seen," in *",$key,"*) ;; *) new=yes; break ;; esac
  done
  if [ "$new" = no ]; then echo "same $last"; return 0; fi
  round=$(( last + 1 ))
  if [ "$round" -gt "$max" ] && [ "$force" != --force ]; then echo "over $round"; return 0; fi
  echo "new $round $seen"
}

round_triage() {
  local f="$1" out
  [ -f "$f" ] || { echo "0 no 0"; return 0; }
  out="$(awk -F'|' '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    /^Round:/ { round = trim(substr($0, 7)) }
    /^Replied:/ { replied = trim(substr($0, 9)) }
    /^\|/ {
      if (!col) {   # the header row: Round comes first, then find the Verdict column
        if (round !~ /^[0-9]+$/) { print "no \"Round: <n>\" line with the round it triaged, above its table"; bad = 1; exit }
        for (i = 2; i < NF; i++) if (trim($i) == "Verdict") col = i
        if (!col) { print "no Verdict column in its table"; bad = 1; exit }
        next
      }
      v = trim($col)
      if (v ~ /^:?-+:?$/) next   # the |---| separator row
      if (v == "ASK") asks++
      else if (v != "FIX" && v != "PUSH BACK") { print "the verdict \"" v "\" in row " trim($2) " (use FIX, PUSH BACK or ASK)"; bad = 1; exit }
    }
    END {
      if (bad) exit 1
      if (round !~ /^[0-9]+$/) { print "no \"Round: <n>\" line with the round it triaged"; exit 1 }
      if (!col) { print "no table with a Verdict column"; exit 1 }
      print round, (replied == "yes" ? "yes" : "no"), asks + 0
    }' "$f")" || { echo "${f##*/} doesn't follow the review-responder's template: $out" >&2; return 1; }
  printf '%s\n' "$out"
}

round_thread() {
  local t
  [ -f "$1" ] || { echo "No ${1##*/}: fetch the review first." >&2; return 1; }
  t="$(jq -c --arg id "$2" 'map(select(.id == $id)) | .[0] // empty' "$1")" || return 1
  [ -n "$t" ] || { echo "No thread $2 in ${1##*/}." >&2; return 1; }
  jq -r '([.file, .new_line, .head_sha] | map(. // "" | tostring) | join("\u001f")), (.body // "")' <<<"$t"
}
