#!/usr/bin/env bash
# Tests scripts/agent/forge-lib.sh (#103), the only code that runs glab, through
# its interface, against the shared fake glab in tests/lib/fake-glab.
# Usage: tests/test-forge.sh     (exit 0 = all passed)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
check() { if eval "$2"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; sed 's/^/      /' "$T/out.txt" 2>/dev/null; fi; }

export FAKE_FORGE="$T/forge"; mkdir -p "$FAKE_FORGE"
export PATH="$ROOT/tests/lib/fake-glab:$PATH"
# lib <function> [args...]: runs one forge function in a fresh shell, as a script
# that sourced the library would; stdout in $out, stdout+stderr in $T/out.txt.
lib() {
  out="$(bash -c 'set -euo pipefail; source "$1"; shift; "$@"' _ "$ROOT/payload/scripts/agent/forge-lib.sh" "$@" 2> "$T/err.txt")"; rc=$?
  { printf '%s\n' "$out"; cat "$T/err.txt"; } > "$T/out.txt"
}
US=$'\037'
# fields <line>: the MR line with its separators shown as |, for readable checks.
fields() { printf '%s' "$1" | tr "$US" '|'; }

# ---------- forge_me ----------
echo me > "$FAKE_FORGE/me"
lib forge_me
check "forge_me: the glab user" '[ $rc -eq 0 ] && [ "$out" = me ]'
rm "$FAKE_FORGE/me"; lib forge_me
check "forge_me: glab fails, non-zero with glab's message" '[ $rc -ne 0 ] && [ -z "$out" ] && grep -q 401 "$T/out.txt"'
echo "" > "$FAKE_FORGE/me"; lib forge_me
check "forge_me: no username, non-zero" '[ $rc -ne 0 ] && [ -z "$out" ]'
echo me > "$FAKE_FORGE/me"

# ---------- forge_mr ----------
jq -n '{iid: 7, project_id: 1, source_project_id: 1, state: "opened", author: {username: "ann"},
        source_branch: "feature/x", target_branch: "main",
        diff_refs: {base_sha: "b1", start_sha: "s1", head_sha: "h1"}}' > "$FAKE_FORGE/mr-7.json"
lib forge_mr 7
check "forge_mr: iid state author source target fork head base start" '[ $rc -eq 0 ] && [ "$(fields "$out")" = "7|opened|ann|feature/x|main|no|h1|b1|s1" ]'
check "forge_mr: one line" '[ "$(printf "%s\n" "$out" | wc -l | tr -d " ")" = 1 ]'
jq '.source_project_id = 9 | .author = null | del(.diff_refs)' "$FAKE_FORGE/mr-7.json" > "$FAKE_FORGE/mr-8.json"
lib forge_mr 8
check "forge_mr: a fork MR; empty fields stay in place" '[ $rc -eq 0 ] && [ "$(fields "$out")" = "7|opened||feature/x|main|yes|||" ]'
IFS="$US" read -r _ state author source target fork head _ <<<"$out"
check "forge_mr: read with IFS=\\037 keeps an empty author in place" '[ -z "$author" ] && [ "$source" = feature/x ] && [ "$fork" = yes ]'
lib forge_mr 99
check "forge_mr: an MR glab can't find, non-zero with glab's message" '[ $rc -ne 0 ] && [ -z "$out" ] && grep -q 404 "$T/out.txt"'
jq 'del(.target_branch)' "$FAKE_FORGE/mr-7.json" > "$FAKE_FORGE/mr-9.json"; lib forge_mr 9
check "forge_mr: no target branch, non-zero and says so" '[ $rc -ne 0 ] && [ -z "$out" ] && grep -qi "target branch" "$T/out.txt"'
jq 'del(.state)' "$FAKE_FORGE/mr-7.json" > "$FAKE_FORGE/mr-9.json"; lib forge_mr 9
check "forge_mr: no state, non-zero and says so" '[ $rc -ne 0 ] && [ -z "$out" ] && grep -qi "state" "$T/out.txt"'
lib forge_mr x
check "forge_mr: a non-number iid is refused before glab" '[ $rc -ne 0 ] && ! grep -q "fake glab" "$T/out.txt"'
jq '. + {title: "Add export", description: "Line one\n\nLine three"}' "$FAKE_FORGE/mr-7.json" > "$FAKE_FORGE/mr-11.json"
: > "$FAKE_FORGE/calls.log"; lib forge_mr 11 --with-text
check "forge_mr --with-text: the fact line, then the title, then the description" '[ $rc -eq 0 ] && [ "$(head -n1 <<<"$out" | tr "$US" "|")" = "7|opened|ann|feature/x|main|no|h1|b1|s1" ] && [ "$(sed -n 2p <<<"$out")" = "Add export" ] && [ "$(tail -n +3 <<<"$out")" = $'"'"'Line one\n\nLine three'"'"' ]'
check "forge_mr --with-text: one call to GitLab" '[ "$(wc -l < "$FAKE_FORGE/calls.log" | tr -d " ")" = 1 ]'
jq 'del(.title, .description)' "$FAKE_FORGE/mr-11.json" > "$FAKE_FORGE/mr-12.json"; lib forge_mr 12 --with-text
check "forge_mr --with-text: no title or description, nothing after the fact line" '[ $rc -eq 0 ] && [ "$(head -n1 <<<"$out" | tr "$US" "|")" = "7|opened|ann|feature/x|main|no|h1|b1|s1" ] && [ -z "$(tail -n +2 <<<"$out" | tr -d "\n")" ]'
lib forge_mr 11 --text
check "forge_mr: an unknown option is refused before glab" '[ $rc -ne 0 ] && [ -z "$out" ] && grep -q "unknown option" "$T/out.txt"'

# ---------- forge_mr_state ----------
for s in opened merged closed locked; do
  jq --arg s "$s" '.state = $s' "$FAKE_FORGE/mr-7.json" > "$FAKE_FORGE/mr-13.json"; lib forge_mr_state 13
  check "forge_mr_state: an MR that is $s" '[ $rc -eq 0 ] && [ "$out" = "$s" ]'
done
lib forge_mr_state 99
check "forge_mr_state: an MR glab can't find, non-zero and nothing on stdout" '[ $rc -ne 0 ] && [ -z "$out" ]'
: > "$FAKE_FORGE/calls.log"; lib forge_mr_state x
check "forge_mr_state: a non-number iid, non-zero before glab" '[ $rc -ne 0 ] && [ -z "$out" ] && [ ! -s "$FAKE_FORGE/calls.log" ]'
# nobin <tool...>: a PATH holding bash and the given tools only (no glab, or no jq).
nobin() { local d="$T/bin-$*"; d="${d// /-}"; mkdir -p "$d"; local t; for t in bash "$@"; do ln -sf "$(command -v "$t")" "$d/$t"; done; echo "$d"; }
PATH="$(nobin jq)" lib forge_mr_state 7
check "forge_mr_state: no glab, non-zero and nothing on stdout" '[ $rc -ne 0 ] && [ -z "$out" ]'
PATH="$(nobin glab)" lib forge_mr_state 7
check "forge_mr_state: no jq, non-zero and nothing on stdout" '[ $rc -ne 0 ] && [ -z "$out" ]'

# ---------- forge_mr_summary ----------
jq '. + {title: "Export", description: "Closes CU-86abc", web_url: "https://gitlab.test/mr/7", draft: true}' "$FAKE_FORGE/mr-7.json" > "$T/m" && mv "$T/m" "$FAKE_FORGE/mr-7.json"
printf '[{"id":"c1","title":"feat: export","message":"feat: export\\n\\nRefs #86xyz","author_name":"ann"}]' > "$FAKE_FORGE/commits-7.json"
lib forge_mr_summary 7
check "forge_mr_summary: the MR's details and its commits" '[ $rc -eq 0 ] && [ "$(jq -c . <<<"$out")" = "$(jq -nc "{iid: 7, title: \"Export\", description: \"Closes CU-86abc\", source_branch: \"feature/x\", target_branch: \"main\", web_url: \"https://gitlab.test/mr/7\", author: \"ann\", draft: true, commits: [{id: \"c1\", title: \"feat: export\", message: \"feat: export\n\nRefs #86xyz\"}]}")" ]'
jq 'del(.draft)' "$FAKE_FORGE/mr-7.json" > "$FAKE_FORGE/mr-10.json"
lib forge_mr_summary 10
check "forge_mr_summary: no draft field is false, no commits is []" '[ $rc -eq 0 ] && [ "$(jq -c "[.draft, .commits]" <<<"$out")" = "[false,[]]" ]'
lib forge_mr_summary 99
check "forge_mr_summary: an MR glab can't find, non-zero" '[ $rc -ne 0 ] && [ -z "$out" ]'

# ---------- forge_discussions ----------
printf '[{"id":"d1","notes":[{"system":true}]},{"id":"d2","notes":[]}]' > "$FAKE_FORGE/discussions-7.json"
lib forge_discussions 7
check "forge_discussions: every discussion, unfiltered" '[ $rc -eq 0 ] && [ "$(jq -c "map(.id)" <<<"$out")" = "[\"d1\",\"d2\"]" ]'
lib forge_discussions 10
check "forge_discussions: none is []" '[ $rc -eq 0 ] && [ "$(jq -c . <<<"$out")" = "[]" ]'

# ---------- forge_mr_for_branch, forge_mr_create, forge_mr_update ----------
rm -f "$FAKE_FORGE"/mr-*.json; echo 7 > "$FAKE_FORGE/next-iid"
lib forge_mr_for_branch "feat/a b"
check "forge_mr_for_branch: no open MR, nothing printed" '[ $rc -eq 0 ] && [ -z "$out" ]'
lib forge_mr_create "feat/a b" main "Add a" $'Line one\n\nLine two'
check "forge_mr_create: prints the new MR's iid and url" '[ $rc -eq 0 ] && [ "$out" = "7 https://gitlab.test/mr/7" ]'
check "forge_mr_create: an open MR by you, from the branch into the target, not a draft, removing its branch" '[ "$(jq -c "[.state, .author.username, .source_branch, .target_branch, .title, .draft, .force_remove_source_branch]" "$FAKE_FORGE/mr-7.json")" = "[\"opened\",\"me\",\"feat/a b\",\"main\",\"Add a\",false,true]" ] && [ "$(jq -r .description "$FAKE_FORGE/mr-7.json")" = $'"'"'Line one\n\nLine two'"'"' ]'
check "forge_mr_create: one write" '[ "$(cat "$FAKE_FORGE/writes.log")" = "create !7" ]'
lib forge_mr_for_branch "feat/a b"
check "forge_mr_for_branch: finds it, even with a space in the branch" '[ $rc -eq 0 ] && [ "$out" = "7 https://gitlab.test/mr/7" ]'
lib forge_mr_create feat/c main "Add c" "" --draft
check "forge_mr_create --draft: a draft" '[ $rc -eq 0 ] && [ "$out" = "8 https://gitlab.test/mr/8" ] && [ "$(jq .draft "$FAKE_FORGE/mr-8.json")" = true ]'
jq '.state = "merged"' "$FAKE_FORGE/mr-8.json" > "$T/m" && mv "$T/m" "$FAKE_FORGE/mr-8.json"
lib forge_mr_for_branch feat/c
check "forge_mr_for_branch: a merged MR doesn't count" '[ $rc -eq 0 ] && [ -z "$out" ]'
lib forge_mr_update 7 "New title" "New description"
check "forge_mr_update: title and description replaced" '[ $rc -eq 0 ] && [ -z "$out" ] && [ "$(jq -c "[.title, .description]" "$FAKE_FORGE/mr-7.json")" = "[\"New title\",\"New description\"]" ] && tail -n1 "$FAKE_FORGE/writes.log" | grep -qx "update !7"'
lib forge_mr_update 99 t d
check "forge_mr_update: an MR glab can't find, non-zero" '[ $rc -ne 0 ] && grep -q 404 "$T/out.txt"'

# ---------- forge_mr_assign_me (#150) ----------
check "forge_mr_create: a new MR has no assignees" '[ "$(jq -c .assignees "$FAKE_FORGE/mr-7.json")" = "[]" ]'
: > "$FAKE_FORGE/writes.log"; lib forge_mr_assign_me 7
check "forge_mr_assign_me: no assignees, the glab user is assigned, one write" '[ $rc -eq 0 ] && [ -z "$out" ] && [ "$(jq -c "[.assignees[].username]" "$FAKE_FORGE/mr-7.json")" = "[\"me\"]" ] && [ "$(cat "$FAKE_FORGE/writes.log")" = "assign !7" ]'
jq '.assignees = [{id: 5, username: "ann"}]' "$FAKE_FORGE/mr-7.json" > "$T/m" && mv "$T/m" "$FAKE_FORGE/mr-7.json"
: > "$FAKE_FORGE/writes.log"; lib forge_mr_assign_me 7
check "forge_mr_assign_me: someone already assigned, kept, no write" '[ $rc -eq 0 ] && [ "$(jq -c "[.assignees[].username]" "$FAKE_FORGE/mr-7.json")" = "[\"ann\"]" ] && [ ! -s "$FAKE_FORGE/writes.log" ]'
jq 'del(.assignees)' "$FAKE_FORGE/mr-7.json" > "$T/m" && mv "$T/m" "$FAKE_FORGE/mr-7.json"
lib forge_mr_assign_me 7
check "forge_mr_assign_me: no assignees field counts as none" '[ $rc -eq 0 ] && [ "$(jq -c "[.assignees[].username]" "$FAKE_FORGE/mr-7.json")" = "[\"me\"]" ]'
jq '.assignees = []' "$FAKE_FORGE/mr-7.json" > "$T/m" && mv "$T/m" "$FAKE_FORGE/mr-7.json"
mv "$FAKE_FORGE/me" "$T/me"; : > "$FAKE_FORGE/writes.log"; lib forge_mr_assign_me 7
check "forge_mr_assign_me: glab user unknown, non-zero, no write" '[ $rc -ne 0 ] && grep -q 401 "$T/out.txt" && [ ! -s "$FAKE_FORGE/writes.log" ]'
mv "$T/me" "$FAKE_FORGE/me"
lib forge_mr_assign_me 99
check "forge_mr_assign_me: an MR glab can't find, non-zero" '[ $rc -ne 0 ] && grep -q 404 "$T/out.txt"'
: > "$FAKE_FORGE/calls.log"; lib forge_mr_assign_me x
check "forge_mr_assign_me: a non-number iid is refused before glab" '[ $rc -ne 0 ] && [ ! -s "$FAKE_FORGE/calls.log" ]'
# A glab that "creates" without the MR appearing: forge_mr_create fails and says so.
mkdir -p "$T/liar"; printf '#!/bin/sh\ncase "$1" in mr) exit 0 ;; *) echo "[]" ;; esac\n' > "$T/liar/glab"; chmod +x "$T/liar/glab"
PATH="$T/liar:$PATH" lib forge_mr_create feat/d main "Add d" ""
check "forge_mr_create: created but not found, non-zero and says so" '[ $rc -ne 0 ] && [ -z "$out" ] && grep -qi "no open MR" "$T/out.txt"'

# ---------- forge_reply, forge_resolve, forge_post_thread ----------
: > "$FAKE_FORGE/writes.log"
lib forge_reply 7 abc123 $'**[pipeline]** Fixed in 1a2b.\nSecond line'
check "forge_reply: the body as given, one write" '[ $rc -eq 0 ] && [ -z "$out" ] && [ "$(cat "$FAKE_FORGE/reply-1.txt")" = $'"'"'**[pipeline]** Fixed in 1a2b.\nSecond line'"'"' ] && [ "$(cat "$FAKE_FORGE/writes.log")" = "reply !7 abc123" ]'
lib forge_resolve 7 abc123
check "forge_resolve: one write" '[ $rc -eq 0 ] && [ -z "$out" ] && tail -n1 "$FAKE_FORGE/writes.log" | grep -qx "resolve !7 abc123"'
lib forge_reply 7 "../x" body
check "forge_reply: a thread id that isn't one is refused before glab" '[ $rc -ne 0 ] && ! grep -q "fake glab" "$T/out.txt" && [ ! -e "$FAKE_FORGE/reply-2.txt" ]'
lib forge_resolve x abc123
check "forge_resolve: a non-number iid is refused before glab" '[ $rc -ne 0 ] && ! grep -q "fake glab" "$T/out.txt"'
jq -n '{body: "hello", position: {new_line: 3}}' > "$T/thread.json"
lib forge_post_thread 7 "$T/thread.json"
check "forge_post_thread: the request body as given, prints the thread id" '[ $rc -eq 0 ] && [ "$out" = disc1 ] && cmp -s "$T/thread.json" "$FAKE_FORGE/thread-1.json" && tail -n1 "$FAKE_FORGE/writes.log" | grep -qx "thread !7 disc1"'
printf '#!/bin/sh\necho "{}"\n' > "$T/liar/glab"
PATH="$T/liar:$PATH" lib forge_post_thread 7 "$T/thread.json"
check "forge_post_thread: no thread id back, non-zero and says so" '[ $rc -ne 0 ] && [ -z "$out" ] && grep -qi "thread id" "$T/out.txt"'

# ---------- forge_eligible (no glab at all) ----------
# line <state> <author> <target> <fork>: an MR line as forge_mr prints it.
line() { printf '7%s%s%s%s%sfeature/x%s%s%s%s%sh1%sb1%ss1' "$US" "$1" "$US" "$2" "$US" "$US" "$3" "$US" "$4" "$US" "$US" "$US"; }
# elig <expected> <purpose> <state> <author> <target> <fork>: one case of the table.
elig() {
  local want="$1" purpose="$2"; shift 2
  FAKE_FORGE="" lib forge_eligible "$purpose" "$(line "$@")" me main   # any glab call would fail and say "fake glab"
  if [ "$want" = ok ]; then check "forge_eligible $purpose $*: ok" '[ $rc -eq 0 ] && [ -z "$out" ] && ! grep -q "fake glab" "$T/out.txt"'
  else check "forge_eligible $purpose $*: $want" '[ $rc -eq 1 ] && [ "$out" = "$want" ] && ! grep -q "fake glab" "$T/out.txt"'; fi
}
elig ok           review opened ann  dev  yes
elig not-open     review locked ann  main no
elig merged       review merged ann  main no
elig closed       review closed ann  main no
elig ok           adopt  opened me   main no
elig merged       adopt  merged me   main no
elig not-open     adopt  locked me   main no
elig not-mine     adopt  opened ann  main no
elig fork         adopt  opened me   main yes
elig wrong-target adopt  opened me   dev  no
elig not-mine     adopt  opened ann  dev  yes   # the first reason wins
lib forge_eligible ship "$(line opened me main no)" me main
check "forge_eligible: an unknown purpose is an error, not a refusal" '[ $rc -gt 1 ]'

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
