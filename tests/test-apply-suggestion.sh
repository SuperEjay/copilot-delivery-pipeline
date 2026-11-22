#!/usr/bin/env bash
# Tests scripts/agent/apply-suggestion.sh (#95): a review thread's GitLab
# ```suggestion block applied to the working tree, in a scratch repo. It reads
# .work/<task>/review.json, takes the target lines from the commit the reviewer
# saw (head_sha), and refuses (exit 3, nothing written) when it can't apply.
# Usage: tests/test-apply-suggestion.sh     (exit 0 = all passed)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
check() { if eval "$2"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; sed 's/^/      /' "$T/out.txt" 2>/dev/null; fi; }
S=scripts/agent

# ---------- scratch repo with a task ----------
git init -q --bare -b main "$T/remote.git"
git init -q -b main "$T/proj"; cd "$T/proj"
git config user.email t@t; git config user.name t
git remote add origin "$T/remote.git"
mkdir -p scripts; cp -r "$ROOT/payload/scripts/agent" scripts/
printf '.work/\n.agent.env\n' > .gitignore
printf 'l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\n' > a.txt
printf '}\nx\n}\n' > b.txt
git add -A; git commit -qm init; git push -q origin main
$S/start-task.sh T1 sugg > /dev/null 2>&1
SEEN="$(git rev-parse HEAD)"   # the commit the reviewer commented on
W=.work/T1

# thread <id> <file> <new_line|null> <body> [head_sha]: append one thread to
# review.json. A null new_line is a comment on a removed line (line = old_line).
: > "$T/threads.jsonl"
thread() {
  jq -n --arg id "$1" --arg f "$2" --argjson l "$3" --arg b "$4" --arg h "${5-$SEEN}" \
    '{id: $id, author: "duo", file: $f, line: ($l // 3), new_line: $l, body: $b, head_sha: (if $h == "" then null else $h end), replies: []}' >> "$T/threads.jsonl"
  jq -s . "$T/threads.jsonl" > $W/review.json
}
apply() { $S/apply-suggestion.sh T1 "$1" > "$T/out.txt" 2>&1; rc=$?; }
reset() { git checkout -q -- a.txt b.txt; }
F='```'

thread one   a.txt 3 "Use L3.
${F}suggestion
L3
${F}"
thread multi a.txt 4 "${F}suggestion:-1+2
L3
L4 and L5
L6
${F}"
thread empty a.txt 2 "${F}suggestion:-1+0
${F}"
thread two   a.txt 5 "Either
${F}suggestion:-0+0
L5
${F}
or
${F}suggestion:-1+0
L4
L5
${F}"
thread none  a.txt 3 "Just a remark, no code."
thread noline a.txt null "${F}suggestion
L3
${F}"
thread nosha a.txt 3 "${F}suggestion
L3
${F}" ""
thread brace b.txt 3 "${F}suggestion
};
${F}"
thread past  a.txt 8 "${F}suggestion:-0+3
L8
${F}"

# ---------- a single line ----------
apply one
check "one line: applied" '[ $rc -eq 0 ] && [ "$(sed -n 3p a.txt)" = L3 ] && [ "$(wc -l < a.txt)" -eq 8 ]'
check "one line: says where" 'grep -q "a.txt:3" "$T/out.txt"'
check "it doesn't commit" '[ "$(git rev-parse HEAD)" = "$SEEN" ] && [ -n "$(git status --porcelain a.txt)" ]'
reset

# ---------- -N+M: the lines above and below go too ----------
apply multi
check "-1+2 replaces lines 3-6 with three lines" '[ $rc -eq 0 ] && [ "$(cat a.txt | tr "\n" ,)" = "l1,l2,L3,L4 and L5,L6,l7,l8," ]'
reset

# ---------- an empty block deletes ----------
apply empty
check "an empty block deletes lines 1-2" '[ $rc -eq 0 ] && [ "$(cat a.txt | tr "\n" ,)" = "l3,l4,l5,l6,l7,l8," ]'
reset

# ---------- several blocks are alternatives: nothing written ----------
apply two
check "two blocks in one comment: refused, file untouched" '[ $rc -eq 3 ] && grep -q alternatives "$T/out.txt" && git diff --quiet a.txt'

# ---------- the lines moved: a unique match still applies ----------
printf 'new0\n' | cat - a.txt > a.tmp && mv a.tmp a.txt
apply one
check "lines moved down one: applied at the new place" '[ $rc -eq 0 ] && [ "$(sed -n 4p a.txt)" = L3 ] && [ "$(sed -n 3p a.txt)" = l2 ]'
reset

# ---------- the lines changed: stale ----------
sed -i 's/^l3$/changed/' a.txt
apply one
check "the target line changed: refused as stale, untouched" '[ $rc -eq 3 ] && grep -qi stale "$T/out.txt" && [ "$(sed -n 3p a.txt)" = changed ]'
reset

# ---------- moved, and the block isn't unique: stale ----------
printf 'new0\n' | cat - b.txt > b.tmp && mv b.tmp b.txt
apply brace
check "a line that moved and appears twice: refused" '[ $rc -eq 3 ] && [ "$(cat b.txt | tr "\n" ,)" = "new0,},x,}," ]'
reset
apply brace
check "the same block at its own place: applied" '[ $rc -eq 0 ] && [ "$(cat b.txt | tr "\n" ,)" = "},x,};," ]'
reset

# ---------- refusals ----------
apply none
check "no suggestion block: refused" '[ $rc -eq 3 ] && git diff --quiet'
apply noline
check "no new_line: refused" '[ $rc -eq 3 ] && git diff --quiet'
apply nosha
check "no head_sha: refused" '[ $rc -eq 3 ] && git diff --quiet'
apply past
check "a range past the end of the file: refused" '[ $rc -eq 3 ] && git diff --quiet'
apply nope
check "an unknown thread: an error, not a refusal" '[ $rc -ne 0 ] && [ $rc -ne 3 ] && git diff --quiet'

# ---------- a file without a trailing newline keeps it that way ----------
printf 'l1\nl2\nl3' > a.txt; git commit -qam "no newline"; SEEN="$(git rev-parse HEAD)"
: > "$T/threads.jsonl"
thread tail a.txt 3 "${F}suggestion
L3
${F}"
apply tail
check "no trailing newline: kept" '[ $rc -eq 0 ] && [ "$(tail -c 2 a.txt)" = L3 ]'

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
