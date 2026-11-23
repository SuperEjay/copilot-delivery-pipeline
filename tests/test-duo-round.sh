#!/usr/bin/env bash
# Tests scripts/agent/duo-round-lib.sh (#106), the only code that knows a Duo
# round's formats: which threads make up review.json, the round rule and its
# seen set, and review-triage.md, read against the review-responder's own
# template.
# Usage: tests/test-duo-round.sh     (exit 0 = all passed)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
check() { if eval "$2"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; sed 's/^/      /' "$T/out.txt" 2>/dev/null; fi; }
AGENT="$ROOT/payload/.github/agents/review-responder.agent.md"
# lib <function> [args...]: one library function in a fresh shell, as a script
# that sourced it would run it; stdout in $out, stdout+stderr in $T/out.txt.
lib() {
  out="$(bash -c 'set -euo pipefail; source "$1"; shift; "$@"' _ "$ROOT/payload/scripts/agent/duo-round-lib.sh" "$@" 2> "$T/err.txt")"; rc=$?
  { printf '%s\n' "$out"; cat "$T/err.txt"; } > "$T/out.txt"
}
US=$'\037'
# old_seen <pair>...: the seen set as fetch-duo-review.sh recorded it before
# #106 (REVIEW_IDS): one cksum per "id:last-note-id", sorted, comma-separated.
old_seen() { local p; for p in "$@"; do printf '%s' "$p" | cksum | cut -d' ' -f1; done | sort | paste -sd, -; }

# ---------- round_threads: which threads, which fields ----------
# d1 Duo's, with your reply and then Duo's again; d2 Duo's, you replied last;
# d3 ann's; d4 resolved; d5 a plain comment; d6 Duo's on a removed line.
jq -n '[
  {id: "d1", notes: [
     {id: 11, resolvable: true, resolved: false, author: {username: "duo"}, body: "fix it",
      position: {new_path: "a.txt", new_line: 3, old_line: null, head_sha: "h1"}},
     {id: 12, author: {username: "me"}, body: "why?"},
     {id: 13, author: {username: "duo"}, body: "because"}]},
  {id: "d2", notes: [
     {id: 21, resolvable: true, resolved: false, author: {username: "duo"}, body: "and this"},
     {id: 22, author: {username: "me"}, body: "no"}]},
  {id: "d3", notes: [{id: 31, resolvable: true, resolved: false, author: {username: "ann"}, body: "ann asks"}]},
  {id: "d4", notes: [{id: 41, resolvable: true, resolved: true, author: {username: "duo"}, body: "done"}]},
  {id: "d5", notes: [{id: 51, resolvable: false, author: {username: "duo"}, body: "looks fine"}]},
  {id: "d6", notes: [{id: 61, resolvable: true, resolved: false, author: {username: "duo"}, body: "gone",
      position: {old_path: "b.txt", new_path: null, old_line: 7, new_line: null, head_sha: "h6"}}]}
]' > "$T/disc.json"
lib round_threads "$(cat "$T/disc.json")" me "duo"
check "round_threads: unresolved, resolvable, Duo's, not answered by you" '[ $rc -eq 0 ] && [ "$(jq -c "[.review[].id]" <<<"$out")" = "[\"d1\",\"d6\"]" ]'
check "round_threads: the threads you answered are counted as skipped" '[ "$(jq .skipped <<<"$out")" = 1 ]'
check "round_threads: the seen set is each kept thread and its last note, sorted" '[ "$(jq -r .seen <<<"$out")" = "d1:13,d6:61" ]'
check "round_threads: review.json fields, from the first note" '[ "$(jq -c ".review[0] | [.id, .author, .file, .line, .new_line, .head_sha, .body]" <<<"$out")" = "[\"d1\",\"duo\",\"a.txt\",3,3,\"h1\",\"fix it\"]" ]'
check "round_threads: the replies, with their authors" '[ "$(jq -c "[.review[0].replies[] | .author]" <<<"$out")" = "[\"me\",\"duo\"]" ]'
check "round_threads: a removed line falls back to its old path and line, with no new_line" '[ "$(jq -c ".review[1] | [.file, .line, .new_line]" <<<"$out")" = "[\"b.txt\",7,null]" ]'
check "round_threads: no bookkeeping fields in review.json" '[ "$(jq -c "[.review[] | keys[] | select(startswith(\"_\"))]" <<<"$out")" = "[]" ]'
lib round_threads "$(cat "$T/disc.json")" me " duo , ann "
check "round_threads: DUO_USERNAMES is a comma list, spaces trimmed" '[ "$(jq -c "[.review[].id]" <<<"$out")" = "[\"d1\",\"d3\",\"d6\"]" ]'
lib round_threads "$(cat "$T/disc.json")" me ""
check "round_threads: no DUO_USERNAMES, every author" '[ "$(jq -c "[.review[].id]" <<<"$out")" = "[\"d1\",\"d3\",\"d6\"]" ]'
lib round_threads '[]' me duo
check "round_threads: no threads" '[ $rc -eq 0 ] && [ "$(jq -c "[.review, .seen, .skipped]" <<<"$out")" = "[[],\"\",0]" ]'
jq '[ .[] | .notes |= map(.body = (.body + "\n" + ("x" * 500))) ]' "$T/disc.json" > "$T/long.json"
lib round_threads "$(cat "$T/long.json")" me duo
check "round_threads: replies are cut to 400 characters, the first note isn't" '[ "$(jq "[.review[0].replies[].body | length] | max" <<<"$out")" = 400 ] && [ "$(jq ".review[0].body | length" <<<"$out")" -gt 400 ]'

# ---------- round_decide: the round rule ----------
# decide <expected> <last-round> <last-seen> <seen> [--force]: one case, MAX_REVIEW_ROUNDS=3.
decide() {
  local want="$1"; shift
  local a=("$1" "$2" "$3" 3); [ $# -gt 3 ] && a+=("$4")
  lib round_decide "${a[@]}"
  check "round_decide ${*:-}: $want" '[ $rc -eq 0 ] && [ "$out" = "$want" ]'
}
decide "same 0"                0 ""          ""                    # nothing yet
decide "new 1 a:1,b:2"         0 ""          "a:1,b:2"
decide "same 1"                1 "a:1,b:2"   "a:1,b:2"             # fetched again
decide "same 1"                1 "a:1,b:2"   "a:1"                 # b resolved: nothing new
decide "new 2 a:1,b:3"         1 "a:1,b:2"   "a:1,b:3"             # a new note on b
decide "new 2 a:1,c:9"         1 "a:1"       "a:1,c:9"             # a new thread
decide "same 3"                3 "a:1"       "a:1"                 # at the limit, nothing new
decide "over 4"                3 "a:1"       "a:1,c:9"             # past the limit
decide "new 4 a:1,c:9"         3 "a:1"       "a:1,c:9" --force
decide "same 2"                2 ""          ""                    # all answered or resolved
# Upgrading from REVIEW_IDS (checksums): the same threads are no new round (#106).
decide "same 2"                2 "$(old_seen d1:13 d6:61)" "d1:13,d6:61"
decide "same 2"                2 "$(old_seen d1:13 d6:61)" "d1:13"
decide "new 3 d1:14,d6:61"     2 "$(old_seen d1:13 d6:61)" "d1:14,d6:61"
lib round_decide 1 "" "a:1" 3 --frce
check "round_decide: an unknown option is an error, not a decision" '[ $rc -ne 0 ] && [ -z "$out" ]'
lib round_decide x "" "a:1" 3
check "round_decide: a round that isn't a number is an error" '[ $rc -ne 0 ] && [ -z "$out" ]'

# ---------- round_triage: review-triage.md, against the agent's own template ----------
# template: the first ~~~markdown block under "## review-triage.md template" in
# review-responder.agent.md.
template() { awk '$0 == "## review-triage.md template" { on = 1; next } on && /^~~~markdown$/ { inb = 1; next } inb && /^~~~$/ { exit } inb' "$AGENT"; }
template > "$T/template.md"
check "the agent has a review-triage.md template: Round, the table, a row to copy" '[ -s "$T/template.md" ] && grep -q "^Round: <n>$" "$T/template.md" && grep -q "^| Thread | File:line | Verdict | Reason | Commit |$" "$T/template.md" && grep -q "^| <thread id> .*<FIX, PUSH BACK or ASK>" "$T/template.md"'
# triage <round> <replied yes|no> <verdict>...: the template filled in, one row per verdict.
triage() {
  local round="$1" replied="$2" v i=0 row; shift 2
  row="$(grep -E '^\| <' "$T/template.md" | head -n1)"
  { grep -vE '^\| <' "$T/template.md" | sed "s/<task-id>/T1/; s/<n>/$round/"
    for v in "$@"; do i=$((i + 1))
      printf '%s\n' "$row" | sed "s/<FIX, PUSH BACK or ASK>/$v/; s/<thread id>/d$i/; s/<[^>]*>/x/g"
    done
  } > "$T/triage.md"
  if [ "$replied" = yes ]; then awk '{ print } /^Round: / { print "Replied: yes" }' "$T/triage.md" > "$T/t" && mv "$T/t" "$T/triage.md"; fi
}
triage 2 no FIX "PUSH BACK" ASK ASK
lib round_triage "$T/triage.md"
check "round_triage: the template filled in: round, not replied, two ASK" '[ $rc -eq 0 ] && [ "$out" = "2 no 2" ]'
triage 3 yes FIX
lib round_triage "$T/triage.md"
check "round_triage: Replied: yes" '[ $rc -eq 0 ] && [ "$out" = "3 yes 0" ]'
lib round_triage "$T/none.md"
check "round_triage: no file yet is round 0" '[ $rc -eq 0 ] && [ "$out" = "0 no 0" ]'
triage 2 no FIX
awk -F'|' 'BEGIN { OFS = "|" } /\| FIX \|/ { $5 = " ASK " } { print }' "$T/triage.md" > "$T/t" && mv "$T/t" "$T/triage.md"
lib round_triage "$T/triage.md"
check "round_triage: ASK in the Reason column is no ASK thread" '[ $rc -eq 0 ] && [ "$out" = "2 no 0" ]'
triage 2 no Fix
lib round_triage "$T/triage.md"
check "round_triage: an unknown verdict is unreadable, and says which" '[ $rc -ne 0 ] && [ -z "$out" ] && grep -q "Fix" "$T/out.txt" && grep -q "FIX, PUSH BACK or ASK" "$T/out.txt"'
triage 2 no FIX; grep -v '^Round:' "$T/triage.md" > "$T/t" && mv "$T/t" "$T/triage.md"
lib round_triage "$T/triage.md"
check "round_triage: no Round line is unreadable" '[ $rc -ne 0 ] && [ -z "$out" ] && grep -q "Round: <n>" "$T/out.txt"'
triage 2 no FIX; sed 's/^Round: 2$/Round: two/' "$T/triage.md" > "$T/t" && mv "$T/t" "$T/triage.md"
lib round_triage "$T/triage.md"
check "round_triage: a Round that isn't a number is unreadable" '[ $rc -ne 0 ] && [ -z "$out" ]'
triage 2 no FIX; sed 's/| Verdict |/| Decision |/' "$T/triage.md" > "$T/t" && mv "$T/t" "$T/triage.md"
lib round_triage "$T/triage.md"
check "round_triage: no Verdict column is unreadable" '[ $rc -ne 0 ] && [ -z "$out" ] && grep -q "Verdict" "$T/out.txt"'
printf 'Round: 1\nReplied: yes\n\n| Verdict | Thread |\n|:--|--|\n|  ASK  | d1 |\n| PUSH BACK | d2 |\n' > "$T/triage.md"
lib round_triage "$T/triage.md"
check "round_triage: the Verdict column found by its header, cells trimmed" '[ $rc -eq 0 ] && [ "$out" = "1 yes 1" ]'

# ---------- round_thread: one thread of review.json, for apply-suggestion.sh ----------
lib round_threads "$(cat "$T/disc.json")" me duo; jq .review <<<"$out" > "$T/review.json"
lib round_thread "$T/review.json" d1
check "round_thread: file, new_line and head_sha on the first line, then the body" '[ $rc -eq 0 ] && [ "$(head -n1 <<<"$out" | tr "$US" "|")" = "a.txt|3|h1" ] && [ "$(tail -n +2 <<<"$out")" = "fix it" ]'
lib round_thread "$T/review.json" d6
check "round_thread: a removed line has no new_line" '[ $rc -eq 0 ] && [ "$(head -n1 <<<"$out" | tr "$US" "|")" = "b.txt||h6" ]'
lib round_thread "$T/review.json" d9
check "round_thread: an unknown thread, non-zero and says so" '[ $rc -ne 0 ] && [ -z "$out" ] && grep -q "d9" "$T/out.txt"'
lib round_thread "$T/missing.json" d1
check "round_thread: no review.json, non-zero" '[ $rc -ne 0 ] && [ -z "$out" ]'

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
