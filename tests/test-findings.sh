#!/usr/bin/env bash
# Tests the findings module (scripts/agent/findings-lib.sh): how code-review.md
# is read and changed, for both routes, including the reviewer agent's own
# templates as written in reviewer.agent.md.
# Usage: tests/test-findings.sh     (exit 0 = all passed)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
check() { if eval "$2"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; sed 's/^/      /' "$T/out.txt" 2>/dev/null; fi; }
# shellcheck source=/dev/null
source "$ROOT/payload/scripts/agent/findings-lib.sh"
AGENT="$ROOT/payload/.github/agents/reviewer.agent.md"
US=$'\037'
# rec <file> <CR-n>: that finding's findings_list record, fields joined by "|".
rec() { findings_list "$1" > "$T/out.txt" 2>&1; awk -F"$US" -v id="$2" '$1 == id { $1 = $1; print }' OFS='|' "$T/out.txt"; }
# template <heading>: the first ~~~markdown block after that "## " heading in reviewer.agent.md.
template() { awk -v h="$1" '$0 == h { on = 1; next } on && /^~~~markdown$/ { inb = 1; next } inb && /^~~~$/ { exit } inb' "$AGENT"; }

# ---------- reading fields ----------
F="$T/code-review.md"
cat > "$F" <<'EOF'
# Code review: T1
## Summary
Risky.
## Findings
### CR-1 · major · Correctness · `src/a.ts:3`
- **Problem:** it says **Decision:** skip in the middle of a sentence.
- **Effort:** S · **Recommend:** fix
- **Decision:** **Fix** · **Route:** `quick`
- **Status:** open, with one line on why
### CR-2 · minor · Style · `src/b.ts:9`
- **Problem:** p
- **Decision:** post | debt | skip
- **Thread:** _pending_
### CR-3 · minor · Docs · `README.md`
- **Problem:** p
- **Decision:** post
- **Thread:** abc123
- **Replied:** yes

- **Status:** verified
## Already raised
- **Status:** open
- Thread 9 (bob): covered.
EOF
check "a field's first word, lower case, markdown stripped; Route after ·; Status before its comma" '[ "$(rec "$F" CR-1)" = "CR-1|fix|quick||open|" ]'
check "a **Decision:** quoted mid-sentence isn't a field" '[ "$(rec "$F" CR-1 | cut -d"|" -f2)" = fix ]'
check "a choice list and _pending_ read as empty" '[ "$(rec "$F" CR-2)" = "CR-2|||||" ]'
check "thread, status and replied; a blank line doesn't end a finding" '[ "$(rec "$F" CR-3)" = "CR-3|post||abc123|verified|yes" ]'
check "a field under a later ## section isn't the last finding's" '[ "$(rec "$F" CR-3 | cut -d"|" -f5)" = verified ] && [ "$(findings_list "$F" | wc -l)" -eq 3 ]'
findings_list "$T/missing.md" > "$T/out.txt" 2>&1; rc=$?
check "no file: findings_list returns 1 quietly" '[ $rc -eq 1 ] && [ ! -s "$T/out.txt" ]'

# ---------- heading and body ----------
check "finding_heading: severity, category, location" '[ "$(finding_heading "$F" CR-1 | tr "$US" "|")" = "major|Correctness|src/a.ts:3" ]'
check "finding_heading: an unknown finding returns 1" '! finding_heading "$F" CR-9 >/dev/null 2>&1'
finding_body "$F" CR-3 > "$T/out.txt"
check "finding_body: no heading, no bookkeeping lines, no trailing blank line" '[ "$(cat "$T/out.txt")" = "- **Problem:** p" ]'
finding_body "$F" CR-1 > "$T/out.txt"
check "finding_body: keeps Problem and Effort" '[ "$(wc -l < "$T/out.txt")" -eq 2 ] && grep -q "Recommend" "$T/out.txt"'
check "finding_body: an unknown finding returns 1" '! finding_body "$F" CR-9 >/dev/null 2>&1'

# ---------- changing the file ----------
cp "$F" "$T/before.md"
finding_set_thread "$F" CR-1 disc7; rc=$?
check "finding_set_thread: the Thread line goes right after that finding's Decision" '[ $rc -eq 0 ] && [ "$(rec "$F" CR-1 | cut -d"|" -f4)" = disc7 ] && [ "$(grep -A1 "Decision:\*\* \*\*Fix" "$F" | tail -n1)" = "- **Thread:** disc7" ]'
check "finding_set_thread: nothing else changes" '[ "$(diff "$T/before.md" "$F" | grep -c "^[<>]")" -eq 1 ]'
finding_set_thread "$F" CR-9 x; rc=$?
check "finding_set_thread: an unknown finding returns 1 and changes nothing" '[ $rc -eq 1 ] && [ "$(grep -c "Thread:" "$F")" -eq 3 ]'
finding_set_thread "$F" CR-2 disc8
check "finding_set_thread: a placeholder Thread line is replaced, not kept below the new one" '[ "$(rec "$F" CR-2 | cut -d"|" -f4)" = disc8 ] && [ "$(awk "/^### CR-2 /{on=1;next} /^#/{on=0} on" "$F" | grep -c "Thread:")" -eq 1 ]'
findings_without_added "$F" > "$T/out.txt"
check "findings_without_added: no Thread or Replied lines, everything else kept" '! grep -qE "^- \*\*(Thread|Replied):" "$T/out.txt" && [ "$(wc -l < "$T/out.txt")" -eq $(( $(wc -l < "$F") - 4 )) ]'

# ---------- the reviewer agent's own templates ----------
template "## Template" > "$T/delivery.md"
check "delivery template: CR-1 is undecided, with no route, and open" '[ "$(rec "$T/delivery.md" CR-1)" = "CR-1||||open|" ]'
template "## In an MR review" > "$T/mr.md"
check "MR review template: CR-1 is undecided" '[ "$(rec "$T/mr.md" CR-1)" = "CR-1|||||" ]'
check "MR review template: the heading reads" '[ "$(finding_heading "$T/mr.md" CR-1 | tr "$US" "|")" = "major|Correctness|src/api/invoices.ts:42" ]'
sed -i 's/^- \*\*Decision:\*\* .*/- **Decision:** post/' "$T/mr.md"
finding_set_thread "$T/mr.md" CR-1 d1
check "MR review template: decided post and posted, it reads back" '[ "$(rec "$T/mr.md" CR-1)" = "CR-1|post||d1||" ]'

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
