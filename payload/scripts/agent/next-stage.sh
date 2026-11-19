#!/usr/bin/env bash
# The auto run's router: decides the next stage, or a stop, from the files in
# .work/<task-id>/, the task state, HEAD and the verified commit. The
# orchestrator follows it without its own judgement. See ADR 0001.
#
#   next-stage.sh <task-id>           print one line:
#       run <agent> <prompt>          run that stage agent as a subagent with
#                                     this prompt (it starts with "AUTO RUN.")
#       stop <stop-id> <reason>       wait for the user's decision; stop ids:
#                                     requirements plan review fix-limit stalled
#                                     pre-ship duo. A file missing a line it
#                                     reads is a stop no approval passes, under
#                                     the stage's id: plan review duo verify
#                                     evidence
#       end <reason>                  the run is over until Duo reviews: the MR
#                                     is open, or a Duo round is answered
#   next-stage.sh <task-id> approve   the user explicitly approved the stop last
#                                     printed: record it, so the run moves on
#
# Exit 0 for any decision. Exit 1 with the reason on stderr when it can't
# decide (no task state yet: run /start-task first; a stage agent has no
# "## In an auto run" section; plan.md has no "## Stop flags" heading, so the
# task predates auto run and goes on stage by stage), or when approve refuses:
# no stop is pending, the stop changed since it was shown, a file needs fixing,
# a review finding has no decision, or the evidence isn't approved at HEAD.
#
# It walks the pipeline in order and the first unfinished step decides:
#   requirements.md   missing: run requirements. Not approved as it is now: stop.
#   plan.md           missing: run planner. Requirements changed since the plan
#                     was accepted: run planner. A Stop flag "yes" or more than
#                     6 S slices: stop (once approved, it goes on); otherwise it
#                     goes on and adds an auto-decision to auto-decisions.md.
#   slices            any "- [ ] S<n>:" or "- [ ] R<n>:" line: run implementer.
#   (MR open)         the Duo round below instead of the next four steps.
#   verified          verification.md "Result: PASS" with "Commit:" = HEAD, and
#                     HEAD is the verified commit. FAIL at HEAD: run implementer
#                     (a fix round). Anything else: run verifier.
#   reviewed          REVIEWED_SHA = HEAD, or run reviewer. In code-review.md, a
#                     finding with no decision, or "Decision: fix" + "Status: open"
#                     routed to requirements or re-plan: stop; once approved,
#                     run requirements (or planner). Open quick fixes: run
#                     implementer (a fix round). Otherwise settled.
#   evidence          evidence/evidence.md "Commit:" = HEAD, or run evidence.
#   pre-ship          mr.md missing: run shipper (write it, don't push). Then the
#                     pre-ship stop; approve needs the evidence approval at HEAD.
#                     Approved: run shipper (ship). MR_IID recorded: end.
#   Duo round         REVIEW_ROUND 0: end. Newer than review-triage.md's "Round:":
#                     run review-responder (triage). "Replied: yes": end. Then
#                     re-verify as above; ASK threads or commits not yet on
#                     origin/<branch>: the duo stop. Then run review-responder
#                     (push and reply).
#
# Lines it reads, which the agents' templates write (anything missing or
# unreadable is a stop no approval can pass):
#   plan.md                "## Stop flags" with "- Requirement gaps: yes|no",
#                          "- Migration: …", "- Feature flag: …", "- Other team: …"
#   verification.md        "Result: PASS|FAIL", "Commit: <HEAD it checked>"
#   code-review.md         "### CR-n …", "- **Decision:** … · **Route:** …",
#                          "- **Status:** …"
#   evidence/evidence.md   "Commit: <HEAD it shows>"
#   review-triage.md       "Round: <n>", "Replied: yes", an "ASK" table cell
#
# Approvals are tied to a checksum of what the stop is about (requirements.md;
# plan.md and requirements.md; code-review.md; HEAD, mr.md, the evidence and
# auto-decisions.md; HEAD and review-triage.md), so a change after approval
# brings the stop back. fix-limit is tied to the fix it's about (verify or
# review, and the commit), and stalled to a checksum of the run's inputs.
# Ticks don't count as a change: building a slice ticks plan.md, and the user
# ticks evidence.md and runs approve-evidence.sh after the pre-ship stop is
# shown (approve then checks the evidence approval itself).
# Fix rounds (MAX_AUTO_FIX_ROUNDS) count each return to the implementer once per
# commit, and start over when a review settles, a Duo round starts or the user
# approves the fix-limit or review stop; approving another stop keeps the count.
# The same run with none of its inputs changed is the stalled stop. When that
# run is the planner updating plan.md for changed requirements, approving it
# keeps the plan as it is. The script writes all this to status.md (Key: value
# lines, read as data, never sourced) and owns that file; the orchestrator only
# reads it.
set -uo pipefail
source "$(dirname "$0")/config.sh"
source "$(dirname "$0")/evidence-lib.sh"

TASK="${1:?usage: next-stage.sh <task-id> [approve]}"
CMD="${2:-}"
case "$CMD" in ""|approve) ;; *) echo "usage: next-stage.sh <task-id> [approve]" >&2; exit 1 ;; esac

state_branch "$TASK" > /dev/null 2>&1 || {
  echo "No task state for $TASK. Run /start-task $TASK <slug> first." >&2
  exit 1
}

DIR="$(task_dir "$TASK")"
STATUS="$DIR/status.md"
REL="${DIR#"$REPO_ROOT"/}"
PLAN_UPDATE="Requirements for $TASK changed; update plan.md."   # the planner's prompt when requirements change

# ---------- before deciding: can this task use an auto run at all? ----------
# A stage agent without its "## In an auto run" section (a file you changed,
# which install.sh --update keeps) writes none of the lines read below, so
# every plan would hit a stop no approval passes. So does a plan.md from
# before auto run, which has no "## Stop flags" heading at all. Neither is a
# stop: the run can't start until it's fixed.
for _agent in requirements planner implementer verifier reviewer evidence shipper review-responder; do
  _af=".github/agents/$_agent.agent.md"
  grep -qx '## In an auto run' "$REPO_ROOT/$_af" 2>/dev/null && continue
  if [ -f "$REPO_ROOT/$_af.new" ]; then
    _fix="Merge $_af.new into it, or run install.sh --update --force to take the new version."
  else
    _fix="Run install.sh --update to get the new version (next to it, to merge, if you changed it), or --update --force to replace it."
  fi
  [ -f "$REPO_ROOT/$_af" ] && _what="has no '## In an auto run' section" || _what="is missing"
  echo "$_af $_what, so an auto run can't use it. $_fix Until then, run the stages yourself." >&2
  exit 1
done
if [ -f "$DIR/plan.md" ] && ! grep -qx '## Stop flags' "$DIR/plan.md"; then
  echo "$TASK was started before auto run ($REL/plan.md has no '## Stop flags' heading). Finish it stage by stage; auto run works for tasks you start from now on." >&2
  exit 1
fi

# ---------- status.md: Key: value lines, parsed, never sourced ----------
# _st <Key>: the value of the last "Key: value" line, or empty.
_st() {
  [ -f "$STATUS" ] || return 0
  awk -v k="$1: " 'index($0, k) == 1 { v = substr($0, length(k) + 1) } END { print v }' "$STATUS"
}

# _fp <file|@HEAD|@unticked:file>...: one checksum over these inputs (a missing
# file counts too). @unticked:<file> reads every "- [x]" as "- [ ]", so ticking
# a slice in plan.md or an item in evidence.md isn't a change to what was approved.
_fp() {
  local f
  for f in "$@"; do
    echo "== $f"
    if [ "$f" = @HEAD ]; then git rev-parse HEAD
    elif [ "${f#@unticked:}" != "$f" ] && [ -f "$DIR/${f#@unticked:}" ]; then
      sed -E 's/^([[:space:]]*- )\[[xX]\]/\1[ ]/' "$DIR/${f#@unticked:}"
    elif [ -f "$DIR/$f" ]; then cat "$DIR/$f"
    else echo "(none)"; fi
  done | sha256 /dev/stdin | cut -c1-16
}

# _approved <stop-id> <fp>: the user approved this stop at this fingerprint.
_approved() { [ -n "$2" ] && [ "$(_st "Approved $1")" = "$2" ]; }

# ---------- the decision ----------
# decide sets VERB (run|stop|end), WHAT (agent or stop id), TEXT (prompt or
# reason), STAGE, and for a stop STOP_FP: the fingerprint an approval is tied to.
_run()  { VERB=run;  WHAT="$1"; TEXT="AUTO RUN. $2"; }
_stop() { VERB=stop; WHAT="$1"; STOP_FP="$2"; TEXT="$3"; }
_end()  { VERB=end;  WHAT=""; TEXT="$1"; }
# _fix_run <key> <prompt>: back to the implementer for a fix. The key (the
# commit it fixes) makes a round count once, however often this is asked.
_fix_run() { FIX_KEY="$1"; _run implementer "$2"; }
# _unreadable <stop-id> <reason>: a stop no approval can pass; the file needs fixing.
_unreadable() { VERB=stop; WHAT="$1"; STOP_FP=""; TEXT="$2"; }

# _plan_flag <name>: yes or no from "- <name>: yes|no" under "## Stop flags".
_plan_flag() {
  awk -v k="- $1:" '/^## / { on = ($0 == "## Stop flags") } on && index($0, k) == 1 { v = tolower(substr($0, length(k) + 1)) }
                    END { gsub(/[ \t]/, "", v); print v }' "$DIR/plan.md"
}

# check_plan <requirements fp>: decide whether the plan may go on (sets PLAN_ACCEPTED
# and AUTO_PLAN), or set a run/stop. Returns 1 when it set a decision.
check_plan() {
  local rfp="$1" pfp acc name v n reasons=() sfp
  pfp="$(_fp @unticked:plan.md)"; acc="$(_st "Plan accepted")"
  if [ -n "$acc" ] && [ "${acc% *}" = "$pfp" ] && [ "${acc#* }" != "$rfp" ]; then
    _run planner "$PLAN_UPDATE"; return 1
  fi
  [ "$acc" = "$pfp $rfp" ] && return 0

  for name in "Requirement gaps" "Migration" "Feature flag" "Other team"; do
    v="$(_plan_flag "$name")"
    case "$v" in
      yes) reasons+=("$name") ;;
      no) ;;
      *) _unreadable plan "$REL/plan.md has no readable '- $name: yes|no' line under '## Stop flags'. The planner must write it."; return 1 ;;
    esac
  done
  n="$(grep -cE '^- \[[ xX]\] S[0-9]+:' "$DIR/plan.md")"
  [ "$n" -gt 6 ] && reasons+=("$n slices (more than 6)")

  if [ "${#reasons[@]}" -gt 0 ]; then
    sfp="$(_fp @unticked:plan.md requirements.md)"
    if ! _approved plan "$sfp"; then
      local IFS=,; _stop plan "$sfp" "Review $REL/plan.md: it flags ${reasons[*]}."; return 1
    fi
  else
    AUTO_PLAN="$n"
  fi
  PLAN_ACCEPTED="$pfp $rfp"
}

decide() {
  STAGE=requirements
  if [ ! -f "$DIR/requirements.md" ]; then _run requirements "Analyse $TASK."; return; fi
  local fp; fp="$(_fp requirements.md)"
  if ! _approved requirements "$fp"; then
    _stop requirements "$fp" "Review $REL/requirements.md: answer its open questions here, or approve it."; return
  fi

  STAGE=plan
  if [ ! -f "$DIR/plan.md" ]; then _run planner "Plan $TASK."; return; fi
  check_plan "$fp" || return

  STAGE=build
  if grep -qE '^- \[ \] [SR][0-9]+:' "$DIR/plan.md"; then
    _run implementer "Build $TASK: implement the next unchecked slice in plan.md."; return
  fi

  if state_mr_iid "$TASK" > /dev/null 2>&1; then STAGE=duo; check_duo; return; fi

  STAGE=verify
  check_verified || return

  STAGE=review
  check_review || return

  STAGE=evidence
  if [ -f "$DIR/evidence/evidence.md" ]; then
    local ec; ec="$(_field evidence/evidence.md Commit)"
    if [ -z "$ec" ]; then
      _unreadable evidence "$REL/evidence/evidence.md has no 'Commit:' line. The evidence agent must write the HEAD it captured."; return
    fi
  fi
  if [ "${ec:-}" != "$(git rev-parse HEAD)" ]; then _run evidence "Capture evidence for $TASK."; return; fi

  STAGE=ship
  if [ ! -f "$DIR/mr.md" ]; then _run shipper "Write mr.md for $TASK. Don't push or create the MR."; return; fi
  fp="$(_fp @HEAD mr.md @unticked:evidence/evidence.md auto-decisions.md)"
  if ! _approved pre-ship "$fp"; then
    local why
    why="$(approval_verify "$TASK" 2>&1 > /dev/null)" || APPROVE_BLOCK="$why"
    _stop pre-ship "$fp" "Before the push: review $REL/evidence/evidence.md, $REL/mr.md and $REL/auto-decisions.md. Tick the evidence you approve and run scripts/agent/approve-evidence.sh $TASK in your own terminal. Approving this stop confirms the push."
    return
  fi
  _run shipper "Ship $TASK. The user confirmed the push at the pre-ship stop."
}

# check_duo: the MR is open. /fetch-review moves the Duo round on; each round
# is triaged, re-verified, and pushed and replied to, with one stop before the
# push when there are ASK threads or commits to push.
check_duo() {
  local round tr head pushed asks fp why=""
  round="$(state_review_round "$TASK")"
  if [ "$round" = 0 ]; then _end "MR open. Run /fetch-review $TASK after Duo has reviewed it."; return; fi
  if [ -f "$DIR/review-triage.md" ]; then
    tr="$(_field review-triage.md Round)"
    case "$tr" in
      ''|*[!0-9]*) _unreadable duo "$REL/review-triage.md has no 'Round: <n>' line. The review-responder must write the round it triaged."; return ;;
    esac
  fi
  if [ "${tr:-0}" -lt "$round" ]; then
    RESET_ROUNDS=1; _run review-responder "Triage $TASK."; return
  fi
  if [ "$(_field review-triage.md Replied)" = yes ]; then
    _end "Duo round $round is answered. Run /fetch-review $TASK after the next review."; return
  fi

  check_verified "Re-verify" || return

  head="$(git rev-parse HEAD)"
  pushed="$(git rev-parse --verify -q "refs/remotes/origin/$(state_branch "$TASK")" || true)"
  asks="$(awk -F'|' '{ for (i = 2; i < NF; i++) { c = $i; gsub(/^[ \t]+|[ \t]+$/, "", c); if (c == "ASK") { n++; break } } } END { print n + 0 }' "$DIR/review-triage.md")"
  if [ "$asks" -gt 0 ] || [ "$pushed" != "$head" ]; then
    fp="$(_fp @HEAD review-triage.md)"
    if ! _approved duo "$fp"; then
      [ "$asks" -gt 0 ] && why=" $asks ASK thread(s) wait for you; they get no reply."
      [ "$pushed" != "$head" ] && why="$why Approving confirms the push of the verified fixes."
      _stop duo "$fp" "Review $REL/review-triage.md.$why"; return
    fi
  fi
  _run review-responder "Push and reply $TASK."
}

# _field <file> <Key>: the value after the last "Key:" line, first word only.
_field() {
  [ -f "$DIR/$1" ] || return 0
  awk -v k="$2:" 'index($0, k) == 1 { split(substr($0, length(k) + 1), w, " "); v = w[1] } END { print v }' "$DIR/$1"
}

# check_verified [verb]: HEAD is verified (verification.md PASS at HEAD, and HEAD is
# the verified commit), or set a run/stop and return 1.
check_verified() {
  local verb="${1:-Verify}" head vc vr
  head="$(git rev-parse HEAD)"
  if [ -f "$DIR/verification.md" ]; then
    vc="$(_field verification.md Commit)"; vr="$(_field verification.md Result)"
    if [ -z "$vc" ]; then
      _unreadable verify "$REL/verification.md has no 'Commit:' line. The verifier must write the HEAD it checked."; return 1
    fi
    if [ "$vc" = "$head" ]; then
      case "$vr" in
        FAIL) _fix_run "verify:$head" "Fix the verification failures for $TASK (see verification.md)."; return 1 ;;
        PASS) [ "$(cat "$DIR/verified-head" 2>/dev/null)" = "$head" ] && return 0 ;;
        *) _unreadable verify "$REL/verification.md has no 'Result: PASS|FAIL' line."; return 1 ;;
      esac
    fi
  fi
  _run verifier "$verb $TASK."; return 1
}

# _findings: "<CR-n>\t<decision>\t<route>\t<status>" for each finding in
# code-review.md, from its "- **Decision:** x · **Route:** y" and
# "- **Status:** z" lines. _pending_ and _(set if fix…)_ placeholders read as empty.
_findings() {
  awk '
    function val(s, key,   i) { i = index(s, key); if (!i) return ""; s = substr(s, i + length(key))
      sub(/·.*/, "", s); gsub(/[*_]/, "", s); sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s)
      if (s ~ /^\(/ || s == "pending") s = ""; split(s, w, " "); return tolower(w[1]) }
    function flush() { if (id != "") print id "\037" d "\037" r "\037" st }
    /^### CR-[0-9]+/ { flush(); id = $2; d = r = st = "" }
    id != "" && /\*\*Decision:\*\*/ { d = val($0, "**Decision:**"); r = val($0, "**Route:**") }
    id != "" && /\*\*Status:\*\*/ { st = val($0, "**Status:**") }
    END { flush() }' "$DIR/code-review.md"
}

# check_review: the review at HEAD is settled, or set a run/stop and return 1.
# Open quick fixes go back to the implementer; a finding with no decision, or
# a fix routed to requirements or re-plan, stops for the user. Approving that
# stop sends the run to the furthest-back route.
check_review() {
  local head id d r st pending=() req=() replan=() quick=() fp
  head="$(git rev-parse HEAD)"
  if [ "$(state_reviewed_sha "$TASK")" != "$head" ]; then _run reviewer "Review $TASK."; return 1; fi
  if [ ! -f "$DIR/code-review.md" ]; then
    _unreadable review "HEAD was reviewed, but there's no $REL/code-review.md. Run the reviewer again by hand."; return 1
  fi
  while IFS=$'\037' read -r id d r st; do
    case "$d" in
      fix) [ "$st" = open ] || continue
           case "$r" in quick) quick+=("$id") ;; requirements) req+=("$id") ;; re-plan) replan+=("$id") ;; *) pending+=("$id") ;; esac ;;
      debt|skip) ;;
      *) pending+=("$id") ;;
    esac
  done < <(_findings)

  if [ $(( ${#pending[@]} + ${#req[@]} + ${#replan[@]} )) -gt 0 ]; then
    fp="$(_fp code-review.md)"
    if [ "${#pending[@]}" -eq 0 ] && _approved review "$fp"; then
      if [ "${#req[@]}" -gt 0 ]; then
        _run requirements "Update requirements for $TASK from the code review (Route: requirements in code-review.md)."
      else
        _run planner "Re-plan the review findings for $TASK (Route: re-plan in code-review.md)."
      fi
      return 1
    fi
    local why=""
    [ "${#pending[@]}" -gt 0 ] && why="$why no clear decision or route: ${pending[*]};" && APPROVE_BLOCK="Decide ${pending[*]} first (fix with a route, debt or skip); approval can't decide for you."
    [ "${#req[@]}" -gt 0 ] && why="$why routed to requirements: ${req[*]};"
    [ "${#replan[@]}" -gt 0 ] && why="$why routed to re-plan: ${replan[*]};"
    _stop review "$fp" "Review $REL/code-review.md:${why%;}."
    return 1
  fi
  if [ "${#quick[@]}" -gt 0 ]; then
    _fix_run "review:$head" "Fix the review findings for $TASK (Decision: fix, Route: quick, Status: open in code-review.md)."
    return 1
  fi
  RESET_ROUNDS=1
}

# apply_fix_round: count a new fix round, or turn it into the fix-limit stop.
apply_fix_round() {
  local round key
  round="$(_st "Fix round")"; round="${round%%/*}"; round="${round:-0}"; key="$(_st "Fix key")"
  NEW_ROUND="$round"; NEW_KEY="$key"
  [ -n "$RESET_ROUNDS" ] && NEW_ROUND=0
  [ "$VERB" = run ] && [ -n "$FIX_KEY" ] && [ "$FIX_KEY" != "$key" ] || return 0
  if [ "$round" -ge "$MAX_AUTO_FIX_ROUNDS" ]; then
    _stop fix-limit "$FIX_KEY" "$MAX_AUTO_FIX_ROUNDS fix rounds used (MAX_AUTO_FIX_ROUNDS) and the work still needs fixing: $TEXT Approve to allow more rounds, or tell me how to go on."
    return 0
  fi
  NEW_ROUND=$(( round + 1 )); NEW_KEY="$FIX_KEY"
}

# check_stall: the same run as last time, with none of its inputs changed,
# means the stage ran and changed nothing: stop instead of looping. Approving
# that stop lets the stage run once more.
INPUTS=(@HEAD requirements.md plan.md verification.md code-review.md evidence/evidence.md
        evidence/APPROVED mr.md auto-decisions.md review-triage.md state.env verified-head)
check_stall() {
  [ "$VERB" = run ] || return 0
  INPUTS_FP="$(_fp "${INPUTS[@]}")"
  LAST_RUN="run $WHAT $TEXT"; LAST_RUN_FP="$INPUTS_FP"
  [ "$LAST_RUN" = "$(_st "Last run")" ] && [ "$INPUTS_FP" = "$(_st "Last run inputs")" ] || return 0
  if _approved stalled "$INPUTS_FP"; then _drop_approval stalled; return 0; fi
  local offer="Approve to run it once more"
  _plan_update_stalled && offer="Approve to keep plan.md as it is for the new requirements"
  _stop stalled "$INPUTS_FP" "$WHAT ran but changed nothing in $REL or the code. $offer, or tell me how to go on. It would get: $TEXT"
}
# _plan_update_stalled: the stalled run is the planner updating plan.md for
# changed requirements. Approving that stop accepts the plan as it is.
_plan_update_stalled() { [ "$LAST_RUN" = "run planner AUTO RUN. $PLAN_UPDATE" ]; }


# ---------- auto-decisions.md ----------
_auto_decision() {
  local f="$DIR/auto-decisions.md"
  [ -f "$f" ] || printf '# Auto-decisions: %s\nDecisions the pipeline made for you in an auto run. Review them before shipping.\n' "$TASK" > "$f"
  printf '\n## %s\n- **When:** %s\n- **What:** %s\n- **Why:** %s\n- **Rule:** %s\n' \
    "$1" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$2" "$3" "$4" >> "$f"
}
record_auto_plan() {
  _auto_decision "Plan accepted without a stop" \
    "plan.md ($1 slices) went on to the implementer." \
    "none of its Stop flags is \"yes\", and it has 6 or fewer slices." \
    "Plan: stop only on requirement gaps, a migration, a feature flag, another team's work, or more than 6 slices (ADR 0001)."
}

# ---------- status.md writer ----------
write_status() {
  local pending=""
  [ "$VERB" = stop ] && pending="$WHAT $STOP_FP"
  mkdir -p "$DIR"
  {
    echo "# Auto run status: $TASK"
    echo "Written by scripts/agent/next-stage.sh. Don't edit it."
    echo
    echo "Stage: $STAGE"
    echo "Last decision: $LINE"
    echo "Last run: ${LAST_RUN:-$(_st "Last run")}"
    echo "Last run inputs: ${LAST_RUN_FP:-$(_st "Last run inputs")}"
    echo "Pending stop: $pending"
    echo "Fix round: $NEW_ROUND/$MAX_AUTO_FIX_ROUNDS"
    echo "Fix key: $NEW_KEY"
    echo "Plan accepted: ${PLAN_ACCEPTED:-$(_st "Plan accepted")}"
    if [ -n "$APPROVALS" ]; then sed 's/^/Approved /' <<<"$APPROVALS"; fi
  } > "$STATUS.tmp"
  mv "$STATUS.tmp" "$STATUS"
}

# Approvals: one fingerprint per stop id.
# A plain list of "<stop-id>: <fingerprint>" lines: bash 3.2 (macOS) has no
# associative arrays.
APPROVALS="$(grep '^Approved [a-z-]*: ' "$STATUS" 2>/dev/null | sed 's/^Approved //')"
_drop_approval() { APPROVALS="$(grep -v "^$1: " <<<"$APPROVALS")"; }
_set_approval() { _drop_approval "$1"; APPROVALS="${APPROVALS:+$APPROVALS$'\n'}$1: $2"; }

PLAN_ACCEPTED=""; AUTO_PLAN=""; FIX_KEY=""; LAST_RUN=""; LAST_RUN_FP=""; RESET_ROUNDS=""; APPROVE_BLOCK=""
decide
apply_fix_round
check_stall

if [ "$CMD" = approve ]; then
  pending="$(_st "Pending stop")"
  if [ -z "$pending" ]; then echo "No stop is waiting for an approval." >&2; exit 1; fi
  if [ "$VERB" = stop ] && [ -z "$STOP_FP" ]; then
    echo "This stop can't be approved: $TEXT" >&2; exit 1
  fi
  if [ "$VERB" = stop ] && [ -n "$APPROVE_BLOCK" ]; then
    echo "Not approved: $APPROVE_BLOCK" >&2; exit 1
  fi
  if [ "$VERB" != stop ] || [ "$pending" != "$WHAT $STOP_FP" ]; then
    echo "The stop changed since it was shown. Run next-stage.sh $TASK again and show the user the new stop." >&2
    exit 1
  fi
  _set_approval "$WHAT" "$STOP_FP"
  case "$WHAT" in fix-limit|review) NEW_ROUND=0 ;; esac   # more rounds allowed, or the findings were decided: the count starts over
  PLAN_ACCEPTED=""
  if [ "$WHAT" = stalled ] && _plan_update_stalled; then
    PLAN_ACCEPTED="$(_fp @unticked:plan.md) $(_fp requirements.md)"   # keep the plan for the new requirements
  fi
  LINE="$(_st "Last decision")"
  write_status
  echo "Approved the $WHAT stop."
  exit 0
fi

case "$VERB" in
  run)  LINE="run $WHAT $TEXT" ;;
  stop) LINE="stop $WHAT $TEXT" ;;
  end)  LINE="end $TEXT" ;;
esac
write_status
[ -n "$AUTO_PLAN" ] && record_auto_plan "$AUTO_PLAN"
echo "$LINE"
