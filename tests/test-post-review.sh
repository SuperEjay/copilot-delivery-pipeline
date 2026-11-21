#!/usr/bin/env bash
# Tests posting an MR review's findings (scripts/agent/post-review-thread.sh,
# ADR 0003), and the review signals for an MR review (review-signals.sh), in a scratch repo with a stub glab that keeps each request body:
# a finding on a line inside the MR's diff becomes a diff thread there, any
# other finding a general thread, and each thread id goes back into
# code-review.md.
# Usage: tests/test-post-review.sh     (exit 0 = all passed)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
check() { if eval "$2"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; sed 's/^/      /' "$T/out.txt" 2>/dev/null; fi; }
S=scripts/agent

# ---------- stub glab: the MR from $STUB/mr.json; a POST saves its body ----------
export STUB="$T/stub"; mkdir -p "$STUB"
cat > "$STUB/glab" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$STUB/calls.log"
case "$*" in
  "api -X POST projects/:id/merge_requests/7/discussions"*)
    n=$(( $(ls "$STUB"/post-*.json 2>/dev/null | wc -l) + 1 ))
    while [ $# -gt 0 ]; do [ "$1" = --input ] && cp "$2" "$STUB/post-$n.json"; shift; done
    echo "{\"id\":\"disc$n\"}" ;;
  "api projects/:id/merge_requests/7") cat "$STUB/mr.json" ;;
  *) echo "stub glab: unexpected $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$STUB/glab"; export PATH="$STUB:$PATH"

# ---------- scratch repo: main, and the MR's head in its review worktree ----------
git init -q --bare -b main "$T/remote.git"
git init -q -b main "$T/proj"; cd "$T/proj"
git config user.email t@t; git config user.name t
git remote add origin "$T/remote.git"
mkdir -p scripts; cp -r "$ROOT/payload/scripts/agent" scripts/
printf '.work/\n.agent.env\n' > .gitignore
mkdir src; printf 'one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n' > src/a.ts; echo keep > src/b.ts
git add -A; git commit -qm init; git push -q origin main
BASE="$(git rev-parse HEAD)"
WT="$(bash -c 'source scripts/agent/config.sh; review_worktree mr-7')"
git worktree add -q --detach "$WT" main
sed -i 's/^three$/THREE/' "$WT/src/a.ts"; echo new > "$WT/src/c.ts"; git -C "$WT" add -A; git -C "$WT" commit -qm "the MR"
HEAD="$(git -C "$WT" rev-parse HEAD)"
bash -c 'source scripts/agent/config.sh; state_init_review mr-7 7 && state_set_target_branch mr-7 main'
mr_json() { jq -n --arg b "$BASE" --arg h "${1:-$HEAD}" '{iid: 7, state: "opened", diff_refs: {base_sha: $b, start_sha: $b, head_sha: $h}}' > "$STUB/mr.json"; }
mr_json

R=.work/mr-7
# finding <n> <decision> <location>: one finding of an MR review's code-review.md.
finding() {
  printf '### CR-%s · major · Correctness · `%s`\n- **Problem:** problem %s\n- **Evidence:** seen in the diff\n- **Suggestion:** do it right\n- **Decision:** %s\n\n' "$1" "$3" "$1" "$2"
}
{ echo "# Code review: mr-7"; echo "## Findings"
  finding 1 post 'src/a.ts:3'        # an added line
  finding 2 post 'src/a.ts:5'        # an unchanged line inside the hunk
  finding 3 post 'src/b.ts:1'        # a file the MR doesn't change
  finding 4 skip 'src/c.ts:1'
  finding 5 post 'src/c.ts:1'
  finding 6 post 'src/a.ts:9'        # an unchanged line outside the hunk
} > $R/code-review.md
post() { $S/post-review-thread.sh "$@" > "$T/out.txt" 2>&1; rc=$?; }
body() { jq -r "$2" "$STUB/post-$1.json"; }

# ---------- an added line: a diff thread on it ----------
post 7 CR-1
check "CR-1 is posted" '[ $rc -eq 0 ] && [ -f "$STUB/post-1.json" ] && grep -q "Posted CR-1" "$T/out.txt"'
check "it starts with the pipeline review header" '[ "$(body 1 ".body" | head -n1)" = "**[pipeline review] CR-1 · major · Correctness**" ]'
check "the body has the finding, not its decision" 'body 1 .body | grep -q "problem 1" && body 1 .body | grep -q "do it right" && ! body 1 .body | grep -q "Decision"'
check "an added line: anchored with new_line only, at the MR's diff refs" '[ "$(body 1 "[.position.position_type, .position.new_path, .position.new_line, .position.old_line, .position.base_sha, .position.head_sha] | map(tostring) | join(\" \")")" = "text src/a.ts 3 null $BASE $HEAD" ]'
check "the thread id goes into code-review.md under CR-1" 'awk "/^### CR-1 /{on=1;next} /^### /{on=0} on" $R/code-review.md | grep -qx -- "- \*\*Thread:\*\* disc1"'

# ---------- an unchanged line inside the hunk: both line numbers ----------
post 7 CR-2
check "a context line in the diff: anchored with old_line and new_line" '[ $rc -eq 0 ] && [ "$(body 2 "[.position.new_line, .position.old_line] | map(tostring) | join(\" \")")" = "5 5" ]'

# ---------- outside the diff: a general thread ----------
post 7 CR-3
check "a file the MR doesn't change: a general thread" '[ $rc -eq 0 ] && [ "$(body 3 ".position // \"none\"")" = none ] && body 3 .body | grep -q "src/b.ts:1"'
post 7 CR-6
check "a line outside every hunk: a general thread, naming its location" '[ $rc -eq 0 ] && [ "$(body 4 ".position // \"none\"")" = none ] && body 4 .body | grep -q "src/a.ts:9"'
post 7 CR-5
check "a new file's line: anchored" '[ $rc -eq 0 ] && [ "$(body 5 ".position.new_path")" = src/c.ts ]'

# ---------- what the reviewer agent may leave in the file ----------
{ finding 7 'post | debt | skip' 'src/a.ts:3'
  finding 8 post 'src/c.ts:1' | sed 's/^- \*\*Decision:\*\* post$/&\n- **Thread:** _pending_/'
} >> $R/code-review.md
post 7 CR-7
check "the template's choice list is undecided: refused" '[ $rc -eq 1 ] && grep -q "CR-7 is marked nothing, not post" "$T/out.txt"'
post 7 CR-8
check "a _pending_ Thread isn't a thread: CR-8 is posted, and its Thread line replaced" '[ $rc -eq 0 ] && grep -q "Posted CR-8" "$T/out.txt" && [ "$(awk "/^### CR-8 /{on=1;next} /^#/{on=0} on" $R/code-review.md | grep -c "Thread:")" -eq 1 ]'

# ---------- refused ----------
n_before=$(ls "$STUB"/post-*.json | wc -l)
post 7 CR-4
check "a finding not marked post is refused" '[ $rc -eq 1 ] && grep -q "CR-4 is marked skip, not post" "$T/out.txt"'
post 7 CR-1
check "a finding already posted isn't posted twice" '[ $rc -eq 1 ] && grep -q "CR-1 is already posted (thread disc1)" "$T/out.txt"'
post 7 CR-9
check "an unknown finding is refused" '[ $rc -eq 1 ] && grep -q "No CR-9 in .work/mr-7/code-review.md" "$T/out.txt"'
mr_json 0123456789abcdef0123456789abcdef01234567
sed -i 's/^- \*\*Decision:\*\* skip$/- **Decision:** post/' $R/code-review.md
post 7 CR-4
check "the MR moved on since the review: refused, says to review again" '[ $rc -eq 1 ] && grep -q "/review-mr 7" "$T/out.txt"'
check "nothing was sent for a refused post" '[ "$(ls "$STUB"/post-*.json | wc -l)" -eq "$n_before" ]'
mr_json
bash -c 'source scripts/agent/config.sh; state_init T1 feature/T1-x'
post 1 CR-1
check "a task that isn't an MR review is refused" '[ $rc -eq 1 ] && grep -q "No MR review of !1" "$T/out.txt"'

# ---------- replies on an MR review's threads never resolve them ----------
echo "Verified in the new commits." > "$T/reply.md"
: > "$STUB/calls.log"
$S/reply-thread.sh mr-7 disc1 "$T/reply.md" --resolve > "$T/out.txt" 2>&1; rc=$?
check "reply-thread.sh --resolve in an MR review: refused, nothing sent" '[ $rc -eq 1 ] && grep -q "never resolves a thread" "$T/out.txt" && [ ! -s "$STUB/calls.log" ]'
$S/reply-thread.sh mr-7 disc1 "$T/reply.md" > "$T/out.txt" 2>&1; rc=$?
check "reply-thread.sh in an MR review replies on the thread, and doesn't resolve it" '[ $rc -eq 0 ] && grep -q "Replied to disc1" "$T/out.txt" && grep -q "discussions/disc1/notes" "$STUB/calls.log" && ! grep -q "PUT" "$STUB/calls.log"'

# ---------- review signals for an MR review: the worktree, against the target ----------
git commit -q --allow-empty -m "the user's own work"   # the main checkout moves on; it must not matter
sig() { $S/review-signals.sh "$@" > "$T/out.txt" 2>&1; rc=$?; }
sig mr-7
check "signals for an MR review: the MR's diff against its target branch" '[ $rc -eq 0 ] && grep -q "full MR vs origin/main" $R/review-signals.md && grep -q "\`$(git rev-parse --short "$BASE")..$(git -C "$WT" rev-parse --short HEAD)\`" $R/review-signals.md'
check "... listing the MR's files, read in the worktree" 'grep -q "\`src/a.ts\` | 1 | 1 | 10 |" $R/review-signals.md && grep -q "\`src/c.ts\`" $R/review-signals.md && ! grep -q "src/b.ts" $R/review-signals.md'
sig mr-7 --mark-reviewed
check "--mark-reviewed records the MR head, not the user's HEAD" '[ $rc -eq 0 ] && [ "$(bash -c "source scripts/agent/config.sh; state_reviewed_sha mr-7")" = "$HEAD" ]'
echo "// TODO later" >> "$WT/src/c.ts"; git -C "$WT" commit -qam "author pushes again"
sig mr-7
check "a second run covers only the commits since the review" 'grep -q "delta since last review ($(git rev-parse --short "$HEAD"))" $R/review-signals.md && ! grep -q "src/a.ts" $R/review-signals.md && grep -q "TODO later" $R/review-signals.md'
# the author rewrites history: the reviewed head is no longer an ancestor
REVIEWED_NOW="$(git -C "$WT" rev-parse HEAD)"; bash -c 'source scripts/agent/config.sh; state_set_reviewed_sha mr-7 "$1"' _ "$REVIEWED_NOW"
git -C "$WT" checkout -q --detach "$HEAD"; echo rebased > "$WT/src/d.ts"; git -C "$WT" add -A; git -C "$WT" commit -qm "rebased MR"
sig mr-7
check "after a force-push, the review covers the whole MR again, not a range off the old head" 'grep -q "full MR vs origin/main" $R/review-signals.md && grep -q "src/d.ts" $R/review-signals.md'
sig mr-7 --full
check "--full: the whole MR again" 'grep -q "full MR vs origin/main" $R/review-signals.md && grep -q "src/a.ts" $R/review-signals.md'

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
