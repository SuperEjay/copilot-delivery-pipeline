#!/usr/bin/env bash
# Tests doctor.sh, which checks a project's pipeline setup and changes nothing,
# in a scratch repo with a PATH made only of the tools each case allows.
# Usage: tests/test-doctor.sh     (exit 0 = all passed)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
check() {
  if eval "$2"; then pass=$((pass + 1)); else
    fail=$((fail + 1)); echo "FAIL: $1"; sed 's/^/      /' "$T/out.txt" 2>/dev/null
  fi
}

# ---------- a PATH with only what we allow ----------
# Real system tools the scripts need, linked into $T/sys. Fakes for the tools a
# case turns on or off go in $T/fake: glab (logged in or not), code (a version),
# node, npx, curl, pdftotext, pandoc.
mkdir -p "$T/sys" "$T/fake"
for t in bash sh env git jq sed awk grep cat head tail tr sort uniq cut find xargs wc mktemp rm mkdir dirname basename date uname printf sha256sum shasum od ls; do
  p="$(command -v "$t" 2>/dev/null)" && [ -x "$p" ] && ln -sf "$p" "$T/sys/$t"
done
fake() {   # fake <name> <exit code> [stdout]
  printf '#!/bin/sh\n[ -n "%s" ] && printf "%%s\\n" "%s"\nexit %s\n' "${3:-}" "${3:-}" "$2" > "$T/fake/$1"; chmod +x "$T/fake/$1"
}
unfake() { rm -f "$T/fake/$1"; }
for t in node npx curl; do fake "$t" 0; done
fake glab 0 "Logged in to gitlab.com"   # glab auth status: 0 = logged in
fake code 0 "1.146.0"

# ---------- scratch project with the pipeline installed ----------
git init -q -b main "$T/proj"; cd "$T/proj"
git config user.email t@t; git config user.name t
mkdir -p scripts .github; cp -r "$ROOT/payload/scripts/agent" scripts/
cp -r "$ROOT/payload/.github/hooks" .github/
cp "$ROOT/payload/.agent.env.example" .agent.env.example; cp .agent.env.example .agent.env
printf '.work/\n.agent.env\n' > .gitignore
git add -A; git commit -qm init

# doc [env...]: run doctor.sh with the allowed PATH and a token exported, unless
# the case says otherwise. Output in $T/out.txt, exit code in $rc.
doc() {
  env -i HOME="$T" PATH="$T/fake:$T/sys" CLICKUP_API_TOKEN="pk_test_123" "$@" \
    bash scripts/agent/doctor.sh > "$T/out.txt" 2>&1; rc=$?
}
line() { grep -E "^$1 +$2" "$T/out.txt"; }   # line <PASS|WARN|FAIL|INFO> <ERE>: a result line
snapshot() { find . -path ./.git -prune -o -type f -print | sort | xargs sha256sum; }

# ---------- all good ----------
snapshot > "$T/before"
doc
check "a good setup: exit 0, no FAIL" '[ $rc -eq 0 ] && ! grep -q "^FAIL" "$T/out.txt"'
for t in git curl jq glab node npx; do
  check "PASS: $t found" 'line PASS "$t\\b"'
done
check "PASS: glab logged in" 'line PASS "glab is logged in"'
check "PASS: the token is exported" 'line PASS "CLICKUP_API_TOKEN is exported"'
check "PASS: .agent.env sets every setting" 'line PASS "\.agent\.env sets every setting"'
check "PASS: no CRLF in the scripts" 'line PASS "no CRLF"'
check "PASS: the guard blocked a test git push" 'line PASS "hook guard works"'
check "PASS: VS Code 1.146.0" 'line PASS "VS Code 1\.146\.0"'
check "INFO: pinned models are checked by hand" 'line INFO "pinned models"'
check "the optional tools missing are WARN, not FAIL" 'line WARN "pdftotext" && line WARN "pandoc"'
check "every line is PASS, WARN, FAIL or INFO" '! grep -vqE "^(PASS|WARN|FAIL|INFO) " "$T/out.txt"'
check "it changes no file in the project" 'snapshot | cmp -s - "$T/before"'
check "the guard test leaves no .work/hooks.log behind" '[ ! -e .work ]'
check "it never prints the token" '! grep -q "pk_test_123" "$T/out.txt"'

# ---------- each FAIL ----------
unfake glab; doc
check "glab missing: FAIL, exit 1" '[ $rc -eq 1 ] && line FAIL "glab is missing"'
fake glab 1; doc
check "glab not logged in: FAIL, says how" '[ $rc -eq 1 ] && line FAIL "glab isn.t logged in" && grep -q "glab auth login" "$T/out.txt"'
fake glab 0
env -i HOME="$T" PATH="$T/fake:$T/sys" bash scripts/agent/doctor.sh > "$T/out.txt" 2>&1; rc=$?
check "token not exported: FAIL, says where to put it" '[ $rc -eq 1 ] && line FAIL "CLICKUP_API_TOKEN isn.t exported" && grep -q "shell profile" "$T/out.txt"'
echo 'CLICKUP_API_TOKEN="pk_test_123"' >> .agent.env; doc
check "token in .agent.env: FAIL, value not printed" '[ $rc -eq 1 ] && line FAIL "CLICKUP_API_TOKEN is set in \.agent\.env" && ! grep -q "pk_test_123" "$T/out.txt"'
sed -i '/CLICKUP_API_TOKEN/d' .agent.env
echo 'token: pk_test_123' > notes.txt; git add notes.txt; git commit -qm notes; doc
check "token value in a tracked file: FAIL, names the file, not the value" '[ $rc -eq 1 ] && line FAIL "CLICKUP_API_TOKEN.s value is in a tracked file" && grep -q "notes.txt" "$T/out.txt" && ! grep -q "pk_test_123" "$T/out.txt"'
git rm -q notes.txt; git commit -qm rm
sed -i '/^MAX_AUTO_FIX_ROUNDS=/d' .agent.env; doc
check ".agent.env missing a setting: WARN naming it, exit 0" '[ $rc -eq 0 ] && line WARN "\.agent\.env doesn.t set: MAX_AUTO_FIX_ROUNDS"'
mv .agent.env "$T/env.keep"; doc
check "no .agent.env: FAIL" '[ $rc -eq 1 ] && line FAIL "no \.agent\.env"'
mv "$T/env.keep" .agent.env
printf 'echo hi\r\n' >> scripts/agent/clickup.sh; doc
check "CRLF in a script: FAIL naming it" '[ $rc -eq 1 ] && line FAIL "CRLF" && grep -q "scripts/agent/clickup.sh" "$T/out.txt"'
git checkout -q scripts/agent/clickup.sh
doc PIPELINE_GUARD=off
check "PIPELINE_GUARD=off in this shell: FAIL, the guard is off" '[ $rc -eq 1 ] && line FAIL "hook guard" && grep -q "PIPELINE_GUARD=off" "$T/out.txt"'
mv scripts/agent/hooks/pre-tool-guard.sh "$T/guard.keep"; doc
check "the guard script missing: FAIL" '[ $rc -eq 1 ] && line FAIL "hook guard"'
mv "$T/guard.keep" scripts/agent/hooks/pre-tool-guard.sh
fake code 0 "1.99.2"; doc
check "VS Code older than 1.106: FAIL" '[ $rc -eq 1 ] && line FAIL "VS Code 1\.99\.2 is older than 1\.106"'
unfake code; doc
check "no code on PATH: WARN, can't tell" '[ $rc -eq 0 ] && line WARN "can.t tell the VS Code version"'
fake code 0 "1.146.0"
fake uname 0 "MINGW64_NT-10.0"; doc
check "Windows with Git Bash: FAIL, unsupported, use WSL" '[ $rc -eq 1 ] && line FAIL "Windows with Git Bash is unsupported" && grep -q "WSL" "$T/out.txt"'
unfake uname

# ---------- review worktrees of finished MRs (ADR 0003, #87) ----------
# glab answers the MR's state from $T/mr-<iid>; auth status is logged in.
cat > "$T/fake/glab" <<EOF
#!/bin/sh
case "\$*" in
  "auth status") echo "Logged in to gitlab.com" ;;
  "api projects/:id/merge_requests/"*) cat "$T/mr-\${2##*/}" 2>/dev/null || exit 1 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$T/fake/glab"
doc
check "no review worktrees: no line about them" '! grep -q "review worktree" "$T/out.txt"'
for i in 5 6 8; do git worktree add -q --detach "$(git rev-parse --absolute-git-dir)/pipeline-reviews/mr-$i" HEAD; done
echo '{"state":"merged"}' > "$T/mr-5"; echo '{"state":"closed"}' > "$T/mr-6"; echo '{"state":"opened"}' > "$T/mr-8"
doc
check "a merged MR's review worktree: WARN with the --done command" '[ $rc -eq 0 ] && line WARN "review worktree of MR !5 is still here, and the MR is merged" && grep -q "/review-mr 5 --done" "$T/out.txt"'
check "a closed MR's: WARN too" 'line WARN "review worktree of MR !6 is still here, and the MR is closed" && grep -q "/review-mr 6 --done" "$T/out.txt"'
check "an open MR's worktree is fine: no WARN" '! grep -q "MR !8" "$T/out.txt"'
rm "$T/mr-6"; doc
check "an MR glab can't read: INFO, not a guess" 'line INFO "can.t tell whether MR !6 is still open"'
fake glab 1; doc
check "glab not logged in: no MR states asked for, an INFO" 'line INFO "review worktrees: 3" && ! grep -q "is merged" "$T/out.txt"'
fake glab 0 "Logged in to gitlab.com"
for i in 5 6 8; do git worktree remove --force "$(git rev-parse --absolute-git-dir)/pipeline-reviews/mr-$i"; done

# ---------- it's a pipeline script ----------
check "installed as a pipeline file, executable in git" '[ "$(git -C "$ROOT" ls-files -s payload/scripts/agent/doctor.sh | cut -d" " -f1)" = 100755 ]'
check "runs on bash 3.2: no bash 4 features" '! grep -nE "(declare|local) -A|mapfile|readarray|\$\{[A-Za-z_]+(,,|\^\^)\}" "$ROOT/payload/scripts/agent/doctor.sh"'

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
