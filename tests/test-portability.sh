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
hits=$(cd "$ROOT" && for f in $(find payload/scripts -name '*.sh' ! -name forge-lib.sh | sort); do
  grep -nE '(^|[;&|({`"'"'"'$[:space:]])glab[[:space:]]' "$f" \
    | grep -vE '^[0-9]+:[[:space:]]*#' \
    | grep -vE '^[0-9]+:.*(echo|printf|result) ' \
    | grep -vE 'glab auth status|(require|has)( [a-z]+)* glab|for t in [a-z ]*glab' \
    | sed "s|^|$f:|"
done)
if [ -z "$hits" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: glab run outside forge-lib.sh"; echo "$hits" | sed 's/^/      /'; fi

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
