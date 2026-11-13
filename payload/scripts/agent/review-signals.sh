#!/usr/bin/env bash
# Usage: review-signals.sh <task-id> [--full]
#        review-signals.sh <task-id> --mark-reviewed
#
# Collects cheap, mechanical review signals into .work/<task-id>/review-signals.md,
# so the code reviewer reads a short report plus targeted diffs instead of
# scanning everything. Signals are leads, not verdicts.
#
# The first run covers the whole branch (merge-base with origin/BASE_BRANCH..HEAD).
# After --mark-reviewed, later runs cover only commits since that review (a
# "delta" review of the fixes). --full forces the whole branch again.
set -uo pipefail
source "$(dirname "$0")/config.sh"

TASK="${1:?usage: review-signals.sh <task-id> [--full|--mark-reviewed]}"
MODE="${2:-}"
load_state "$TASK"

if [ "$MODE" = "--mark-reviewed" ]; then
  set_state "$TASK" REVIEWED_SHA "$(git rev-parse HEAD)"
  echo "Marked $(git rev-parse --short HEAD) as reviewed."
  exit 0
fi

: "${REVIEW_TEST_PATTERN:=(\.|_)(test|spec)\.|/__tests__/|/tests?/|/e2e/}"
: "${REVIEW_MIGRATION_PATTERN:=migration|migrate|schema\.(sql|prisma)}"
: "${REVIEW_LARGE_FILE_LINES:=400}"
: "${REVIEW_MAX_PER_FLAG:=15}"

FULL_BASE="$(git merge-base "origin/$BASE_BRANCH" HEAD)"
if [ "$MODE" != "--full" ] && [ -n "${REVIEWED_SHA:-}" ] && git cat-file -e "$REVIEWED_SHA" 2>/dev/null; then
  BASE="$REVIEWED_SHA"; SCOPE="delta since last review ($(git rev-parse --short "$BASE"))"
else
  BASE="$FULL_BASE"; SCOPE="full branch vs origin/$BASE_BRANCH"
fi

OUT="$(task_dir "$TASK")/review-signals.md"
RANGE="$BASE..HEAD"

if [ -z "$(git diff --name-only "$RANGE")" ]; then
  printf '# Review signals: %s\n\nNo changes in %s (%s).\n' "$TASK" "$RANGE" "$SCOPE" > "$OUT"
  echo "No changes to review in $SCOPE."
  exit 0
fi

# Added lines as "file:line:content", from a zero-context diff.
added_lines() {
  git diff -U0 --no-color "$RANGE" | awk '
    /^\+\+\+ b\// { file = substr($0, 7); next }
    /^\+\+\+ /    { file = ""; next }
    /^@@/         { if (match($0, /\+[0-9]+/)) ln = substr($0, RSTART + 1, RLENGTH - 1) + 0; next }
    /^\+/         { if (file != "") print file ":" ln ":" substr($0, 2); ln++; next }'
}

flag() {   # flag "<title>" "<regex>" [exclude-tests]
  local hits
  hits="$(added_lines | grep -E -- "$2" || true)"
  if [ "${3:-}" = "exclude-tests" ]; then hits="$(printf '%s\n' "$hits" | grep -vE "^[^:]*($REVIEW_TEST_PATTERN)" || true)"; fi
  hits="$(printf '%s\n' "$hits" | sed '/^$/d')"
  [ -z "$hits" ] && return
  local n; n="$(printf '%s\n' "$hits" | wc -l | tr -d ' ')"
  echo "### $1 ($n)"
  printf '%s\n' "$hits" | head -n "$REVIEW_MAX_PER_FLAG" | cut -c1-200 | sed 's/^/- /'
  [ "$n" -gt "$REVIEW_MAX_PER_FLAG" ] && echo "- … $((n - REVIEW_MAX_PER_FLAG)) more"
  echo
}

{
  echo "# Review signals: $TASK"
  echo
  echo "Scope: $SCOPE · \`$(git rev-parse --short "$BASE")..$(git rev-parse --short HEAD)\` · $(git diff --shortstat "$RANGE" | sed 's/^ //')"
  echo
  echo "## Changed files (most churn first)"
  echo
  echo "| File | + | − | Lines now | Notes |"
  echo "|---|---|---|---|---|"
  git diff --numstat "$RANGE" | sort -k1,1nr -k2,2nr | while read -r add del path; do
    notes=""; lines="-"
    if [ -f "$path" ]; then
      lines="$(wc -l < "$path" | tr -d ' ')"
      [ "$lines" -ge "$REVIEW_LARGE_FILE_LINES" ] && notes="large file"
    else
      notes="deleted"
    fi
    echo "$path" | grep -qE "$REVIEW_TEST_PATTERN" && notes="${notes:+$notes, }test"
    echo "$path" | grep -qiE "$REVIEW_MIGRATION_PATTERN" && notes="${notes:+$notes, }**migration**"
    echo "| \`$path\` | $add | $del | $lines | $notes |"
  done
  echo

  echo "## Source changed without a matching test change"
  echo
  changed="$(git diff --name-only --diff-filter=AM "$RANGE")"
  tests="$(printf '%s\n' "$changed" | grep -E "$REVIEW_TEST_PATTERN" || true)"
  untested=0
  while read -r f; do
    [ -z "$f" ] && continue
    echo "$f" | grep -qE "$REVIEW_TEST_PATTERN" && continue
    case "$f" in *.md|*.json|*.yml|*.yaml|*.lock|*.css|*.scss|*.svg|*.png) continue ;; esac
    stem="$(basename "$f")"; stem="${stem%%.*}"
    if ! printf '%s\n' "$tests" | grep -q -- "$stem"; then
      echo "- \`$f\`"; untested=$((untested + 1))
    fi
  done <<<"$changed"
  [ "$untested" -eq 0 ] && echo "_None: every changed source file has a test change with a matching name._"
  echo

  echo "## Red flags in added lines"
  echo
  flags="$(
    flag "Leftover TODO / FIXME / HACK" '(TODO|FIXME|HACK|XXX)'
    flag "Debug output" '(console\.(log|debug|trace)|debugger;|print\(|var_dump|dd\()' exclude-tests
    flag "Focused or skipped tests" '(\.only\(|\.skip\(|\bxit\(|\bxdescribe\(|\bfit\(|\bfdescribe\()'
    flag "Type or lint suppressions" '(@ts-ignore|@ts-expect-error|@ts-nocheck|eslint-disable|: any\b|as any\b|# type: ignore|noqa)'
    flag "Possible secret or credential" '(([Pp]ass(word|wd)|[Ss]ecret|[Aa][Pp][Ii][_-]?[Kk][Ee][Yy]|[Aa]ccess[_-]?[Tt]oken|[Pp]rivate[_-]?[Kk]ey|[Cc]lient[_-]?[Ss]ecret)["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"'][^"'"'"']{6,}|(sk|pk|rk)_(live|test)_[A-Za-z0-9]{8,}|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{20,}|glpat-[A-Za-z0-9_-]{20,})'
    flag "Hard-coded URL or host" '(https?://[a-zA-Z0-9.-]+(:[0-9]+)?)' exclude-tests
    flag "Swallowed errors" '(catch[[:space:]]*(\([^)]*\))?[[:space:]]*\{[[:space:]]*\}|except:[[:space:]]*pass|\.catch\(\(\)[[:space:]]*=>[[:space:]]*(\{\}|null|undefined)\))'
    flag "Timing hacks" '(setTimeout\(|sleep\(|waitForTimeout\()'
  )"
  if [ -n "$flags" ]; then printf '%s\n\n' "$flags"; else echo "_None found._"; echo; fi

  if git diff --name-only "$RANGE" | grep -qE '(^|/)package\.json$'; then
    echo "## Dependency changes (package.json)"
    echo
    git diff -U0 --no-color "$RANGE" -- '*package.json' | grep -E '^[+-][[:space:]]+"[^"]+":[[:space:]]*"[^"]*",?$' \
      | grep -vE '"(version|name|description|main|types)"' | sed 's/^/    /' \
      || echo "_package.json changed, but not in a format this script parses. Check \`git diff -- package.json\`._"
    echo
  fi

  if command -v npx >/dev/null 2>&1 && [ -d node_modules/jscpd ]; then
    echo "## Duplication (jscpd, changed files only)"
    echo
    files="$(git diff --name-only --diff-filter=AM "$RANGE" | grep -E '\.(ts|tsx|js|jsx)$' | grep -vE "$REVIEW_TEST_PATTERN" | tr '\n' ' ')"
    if [ -n "$files" ]; then
      # shellcheck disable=SC2086
      npx jscpd --silent --reporters consoleFull --min-lines 8 $files 2>/dev/null | grep -E '^(Clone found|  -)' | head -n 20 | sed 's/^/    /' || true
    fi
    echo
  fi
} > "$OUT"

echo "Review signals ($SCOPE): ${OUT#"$REPO_ROOT"/} ($(wc -l < "$OUT" | tr -d ' ') lines)"
