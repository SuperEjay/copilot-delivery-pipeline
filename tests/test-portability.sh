#!/usr/bin/env bash
# Checks that the pipeline's scripts stay runnable on macOS's own bash 3.2
# (README: "macOS's own bash 3.2 is enough"): no bash 4+ builtins or syntax.
# A static scan, since the tests themselves run on whatever bash is installed.
# Usage: tests/test-portability.sh     (exit 0 = all passed)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
pass=0; fail=0

# Each rule: <ERE pattern> ## <what it is>. The first " ## " splits them.
RULES='\bmapfile\b ## mapfile (bash 4)
\breadarray\b ## readarray (bash 4)
\b(declare|local|typeset) +-[a-zA-Z]*A ## associative arrays (bash 4)
\b(declare|local|typeset) +-[a-zA-Z]*n\b ## namerefs (bash 4.3)
\$\{[a-zA-Z_][a-zA-Z_0-9]*(\[[^]]*\])?(,,?|\^\^?)\} ## case conversion like ${x,,} (bash 4)
\$\{[a-zA-Z_][a-zA-Z_0-9]*(\[[^]]*\])?@[QEPAKa]\} ## ${x@Q} transformations (bash 4.4)
\|&[[:space:]] ## the |& pipe (bash 4)
&>> ## the &>> redirect (bash 4)
\bcoproc\b ## coproc (bash 4)
\bwait +-n\b ## wait -n (bash 4.3)
\$\{[a-zA-Z_][a-zA-Z_0-9]*\[-[0-9]+\]\} ## negative array index (bash 4.3)'

files=$(cd "$ROOT" && { ls install.sh; find payload/scripts -name '*.sh'; } | sort)
while IFS= read -r rule; do
  pat="${rule%% ## *}"; what="${rule#* ## }"
  hits=$(cd "$ROOT" && for f in $files; do grep -nE -- "$pat" "$f" | grep -vE '^[0-9]+:[[:space:]]*#' | sed "s|^|$f:|"; done)
  if [ -z "$hits" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $what"; echo "$hits" | sed 's/^/      /'; fi
done <<< "$RULES"

# The forge module (#103): only forge-lib.sh runs glab. doctor.sh may run
# "glab auth status", a check of the tool itself. A comment, a message, or a
# check that glab is installed (require, has, a doctor tool list) isn't a call.
# glab_calls <file>: the lines of <file> that run glab, as "<n>:<line>". A
# command substitution of glab always is one. Otherwise quoted text (messages)
# and the tool checks are dropped first, and glab must then be a command.
glab_calls() {
  awk '
    /^[ \t]*#/ { next }
    /\$\([ \t]*glab[ \t]/ || /`[ \t]*glab[ \t]/ { print FNR ":" $0; next }
    {
      s = $0
      gsub(/"[^"]*"/, "\"\"", s); gsub(/'"'"'[^'"'"']*'"'"'/, "", s)
      gsub(/glab auth status|(require|has)( [a-z]+)* glab|for t in [a-z ]*glab/, "", s)
      if (s ~ /(^|[;&|({ \t])glab[ \t]/) print FNR ":" $0
    }' "$1"
}
# The rule itself, on lines that are calls and lines that aren't.
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
cat > "$T/calls.sh" <<'LINES'
x="$(glab api projects/:id/merge_requests/1)"; echo "done"
echo "$(glab api user)"
printf '%s\n' "$(glab api user)"
result INFO "$(glab api projects/:id/merge_requests/1 | jq -r .state)"
glab api -X PUT "projects/:id/merge_requests/1" -f a=b || echo "failed"
y=`glab api user`
has glab && glab api user
LINES
cat > "$T/not-calls.sh" <<'LINES'
# glab api user, in a comment
echo "Can't look up your glab user (glab api user). Check glab auth status." >&2
result FAIL "glab isn't logged in: run glab auth login (add --hostname for a self-managed GitLab)"
printf 'Run glab mr view %s yourself.\n' "$IID"
require git glab jq
if has glab && glab auth status >/dev/null 2>&1; then :; fi
for t in git curl jq glab node npx; do :; done
LINES
n_calls=$(wc -l < "$T/calls.sh" | tr -d ' ')
if [ "$(glab_calls "$T/calls.sh" | wc -l | tr -d ' ')" = "$n_calls" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: the glab rule finds every call, also next to a message"; diff <(glab_calls "$T/calls.sh" | cut -d: -f2-) "$T/calls.sh" | sed 's/^/      /'; fi
if [ -z "$(glab_calls "$T/not-calls.sh")" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: the glab rule ignores comments, messages and tool checks"; glab_calls "$T/not-calls.sh" | sed 's/^/      /'; fi

hits=$(cd "$ROOT" && for f in $(find payload/scripts -name '*.sh' ! -name forge-lib.sh | sort); do
  glab_calls "$f" | sed "s|^|$f:|"
done)
if [ -z "$hits" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: glab run outside forge-lib.sh"; echo "$hits" | sed 's/^/      /'; fi

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
