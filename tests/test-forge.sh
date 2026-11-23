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
