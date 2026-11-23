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
#                                     pre-ship duo; in an MR review, spec focus
#                                     findings stalled. A file missing a line it
#                                     reads is a stop no approval passes, under
#                                     the stage's id: plan review duo verify
#                                     evidence spec focus
#       end <reason>                  the run is over until Duo reviews: the MR
#                                     is open, or a Duo round is answered. In an
#                                     MR review: the findings are posted
#   next-stage.sh <task-id> approve   the user explicitly approved the stop last
#                                     printed: record it, so the run moves on
#
# Exit 0 for any decision. Exit 1 with the reason on stderr when it can't
# decide (no task state yet: run /start-task or /review-mr first; a stage agent has no
# "## In an auto run" section), or when approve refuses:
# no stop is pending, the stop changed since it was shown, a file needs fixing,
# a review finding has no decision, or the evidence isn't approved at HEAD.
#
# It walks the pipeline in order and the first unfinished step decides:
#   requirements.md   missing: run requirements. Not approved as it is now: stop.
#   plan.md           missing: run planner (an adopted task, ADR 0004: told to
#                     tick what the branch's commits cover). Requirements changed since the plan
#                     was accepted: run planner. A Stop flag "yes" or more than
#                     MAX_PLAN_SLICES S slices: stop (once approved, it goes
#                     on); otherwise it goes on and adds an auto-decision to
#                     auto-decisions.md.
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
# An MR review (KIND=MR_REVIEW in the task state, ADR 0003) takes its own route,
# read from the review worktree's head instead of HEAD (see decide_review):
#   requirements.md   missing: run requirements. "Spec source: none": the spec
#                     stop; approved, run requirements to use the MR description.
#   focus             more changed files than MR_REVIEW_MAX_FILES (not counting
#                     MR_REVIEW_SKIP_PATTERN): the focus stop, tied to the head
#                     and focus.md.
#   checks            verification.md "Commit:" = the MR head, or run verifier.
#                     PASS or FAIL both go on: failures are findings, not fixes.
#   reviewed          REVIEWED_SHA = the MR head, or run reviewer.
#   findings          always a stop; approve needs post, debt or skip on each.
#   post              a "post" finding without a "Thread:" line: run reviewer
#                     to post it. A posted finding "Status: verified" without a
#                     "Replied:" line: run reviewer to reply on its thread. End.
#   A re-review (the MR's head moved since REVIEWED_SHA) counts only the files
#   changed since then for the focus stop.
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
#   In an MR review:
#   requirements.md        "Spec source: <ClickUp id | MR description (weak) | none>"
#   code-review.md         "### CR-n …", "- **Decision:** post|debt|skip",
#                          "- **Thread:** <discussion id>" once posted,
#                          "- **Status:** verified|open" and "- **Replied:** …"
#                          on a re-review
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
# reads it. It also appends one line per decision and approval to the run log,
# run.log (see log_run).
set -uo pipefail
source "$(dirname "$0")/config.sh"
source "$(dirname "$0")/evidence-lib.sh"
source "$(dirname "$0")/ship-gate.sh"
source "$(dirname "$0")/findings-lib.sh"
source "$(dirname "$0")/duo-round-lib.sh"

# A plan with more S slices than this stops for the user (ADR 0001).
MAX_PLAN_SLICES=6
# The stage agents, the one list of them. An auto run needs each one's
# "## In an auto run" section; a new stage goes here too.
STAGE_AGENTS="requirements planner implementer verifier reviewer evidence shipper review-responder"
# The stage agents with an MR review mode (ADR 0003). An MR review needs each
# one's "## In an MR review" section; an agent gets its mode, then goes here.
REVIEW_AGENTS="requirements verifier reviewer"

TASK="${1:?usage: next-stage.sh <task-id> [approve]}"
CMD="${2:-}"
case "$CMD" in ""|approve) ;; *) echo "usage: next-stage.sh <task-id> [approve]" >&2; exit 1 ;; esac

KIND="$(state_kind "$TASK" 2>/dev/null)" || {
  case "$TASK" in
    mr-*) echo "No task state for $TASK. Run /review-mr ${TASK#mr-} first." >&2 ;;
    *) echo "No task state for $TASK. Run /start-task $TASK <slug> first." >&2 ;;
  esac
  exit 1
}
# The commit the run is about: HEAD, or in an MR review the review worktree's.
HEAD_DIR="$REPO_ROOT"
[ "$KIND" = MR_REVIEW ] && HEAD_DIR="$(review_worktree "$TASK")"
_head() { git -C "$HEAD_DIR" rev-parse "$@" HEAD; }

DIR="$(task_dir "$TASK")"
STATUS="$DIR/status.md"
REL="${DIR#"$REPO_ROOT"/}"
# An adopted task (ADR 0004): every planner prompt says so, the first plan and
# each update, so the planner keeps crediting the branch's existing commits.
ADOPTED_NOTE=""
[ -n "$(state_adopted "$TASK" 2>/dev/null || true)" ] && ADOPTED_NOTE=" The branch was adopted: tick the slices its existing commits already cover."
PLAN_UPDATE="Requirements for $TASK changed; update plan.md.$ADOPTED_NOTE"   # the planner's prompt when requirements change

# ---------- before deciding: can this task use an auto run at all? ----------
# A stage agent without its "## In an auto run" section (a file you changed,
# which install.sh --update keeps) writes none of the lines read below, so
# every plan would hit a stop no approval passes. That isn't a stop: the run
# can't start until it's fixed.
for _agent in $STAGE_AGENTS; do
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

# An MR review also needs the agents' MR review modes. Without one, the agent
# would run its delivery steps on someone else's MR.
if [ "$KIND" = MR_REVIEW ]; then
  for _agent in $REVIEW_AGENTS; do
    _af=".github/agents/$_agent.agent.md"
    grep -qx '## In an MR review' "$REPO_ROOT/$_af" 2>/dev/null && continue
    echo "$_af has no '## In an MR review' section, so an MR review can't use it. Run install.sh --update to get the new version (next to it, to merge, if you changed it), or --update --force to replace it." >&2
    exit 1
  done
fi

# ---------- Key: value lines, parsed, never sourced ----------
# _last_value <file> <prefix> [section]: the rest of the last line that starts
# with <prefix> (only under "## <section>", if given), or empty. A missing file
# is empty too. The readers below trim the value each in their own way.
_last_value() {
  [ -f "$1" ] || return 0
  awk -v k="$2" -v s="${3:-}" 's != "" && /^## / { on = ($0 == "## " s) }
    (s == "" || on) && index($0, k) == 1 { v = substr($0, length(k) + 1) } END { print v }' "$1"
}

# _status_value <Key>: the value of the last "Key: value" line in status.md, or
# empty.
_status_value() { _last_value "$STATUS" "$1: "; }

# _checksum <file|@HEAD|@verified|@unticked:file|@nothreads:file>...: one
# checksum over these inputs (a missing file counts too). @verified is the
# verified commit, from the ship gate (gate_verified). @unticked:<file> reads every "- [x]"
# as "- [ ]", so ticking a slice in plan.md or an item in evidence.md isn't a
# change to what was approved. @nothreads:<file> leaves out the lines added
# after approval (findings_without_added: Thread and Replied), so posting a
# finding or replying on its thread isn't a change to the decisions approved.
_checksum() {
  local f verified
  for f in "$@"; do
    echo "== $f"
    if [ "$f" = @HEAD ]; then _head
    elif [ "$f" = @verified ]; then   # the verified commit, from the ship gate
      verified="$(gate_verified "$TASK")"; if [ -n "$verified" ]; then printf '%s\n' "$verified"; else echo "(none)"; fi
    elif [ "${f#@nothreads:}" != "$f" ] && [ -f "$DIR/${f#@nothreads:}" ]; then
      findings_without_added "$DIR/${f#@nothreads:}"
    elif [ "${f#@unticked:}" != "$f" ] && [ -f "$DIR/${f#@unticked:}" ]; then
      sed -E 's/^([[:space:]]*- )\[[xX]\]/\1[ ]/' "$DIR/${f#@unticked:}"
    elif [ -f "$DIR/$f" ]; then cat "$DIR/$f"
    else echo "(none)"; fi
  done | sha256 /dev/stdin | cut -c1-16
}

# _approved <stop-id> <fp>: the user approved this stop at this fingerprint.
_approved() { [ -n "$2" ] && [ "$(_status_value "Approved $1")" = "$2" ]; }

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
  _last_value "$DIR/plan.md" "- $1:" "Stop flags" | tr -d ' \t' | tr '[:upper:]' '[:lower:]'
}

# check_plan <requirements fp>: decide whether the plan may go on (sets PLAN_ACCEPTED
# and AUTO_PLAN), or set a run/stop. Returns 1 when it set a decision.
check_plan() {
  local rfp="$1" pfp acc name flag n reasons=() sfp
  pfp="$(_checksum @unticked:plan.md)"; acc="$(_status_value "Plan accepted")"
  if [ -n "$acc" ] && [ "${acc% *}" = "$pfp" ] && [ "${acc#* }" != "$rfp" ]; then
    _run planner "$PLAN_UPDATE"; return 1
  fi
  [ "$acc" = "$pfp $rfp" ] && return 0

  for name in "Requirement gaps" "Migration" "Feature flag" "Other team"; do
    flag="$(_plan_flag "$name")"
    case "$flag" in
      yes) reasons+=("$name") ;;
      no) ;;
      *) _unreadable plan "$REL/plan.md has no readable '- $name: yes|no' line under '## Stop flags'. The planner must write it."; return 1 ;;
    esac
  done
  n="$(grep -cE '^- \[[ xX]\] S[0-9]+:' "$DIR/plan.md")"
  [ "$n" -gt "$MAX_PLAN_SLICES" ] && reasons+=("$n slices (more than $MAX_PLAN_SLICES)")

  if [ "${#reasons[@]}" -gt 0 ]; then
    sfp="$(_checksum @unticked:plan.md requirements.md)"
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
  local fp; fp="$(_checksum requirements.md)"
  if ! _approved requirements "$fp"; then
    _stop requirements "$fp" "Review $REL/requirements.md: answer its open questions here, or approve it."; return
  fi

  STAGE=plan
  if [ ! -f "$DIR/plan.md" ]; then _run planner "Plan $TASK.$ADOPTED_NOTE"; return; fi
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
  fp="$(_checksum @HEAD mr.md @unticked:evidence/evidence.md auto-decisions.md)"
  if ! _approved pre-ship "$fp"; then
    local why
    why="$(approval_verify "$TASK" 2>&1 > /dev/null)" || APPROVE_BLOCK="$why"
    local gaps gap_note=""
    gaps="$(sed -n '/^## Gaps/,/^## /p' "$DIR/verification.md" 2>/dev/null | grep -c '^- ')" || true
    [ "${gaps:-0}" -gt 0 ] && gap_note=" $REL/verification.md lists $gaps gap(s), such as checks that were skipped or ACs not tested end to end: read its Gaps section first."
    _stop pre-ship "$fp" "Before the push: review $REL/evidence/evidence.md, $REL/mr.md and $REL/auto-decisions.md.$gap_note Tick the evidence you approve and run scripts/agent/approve-evidence.sh $TASK in your own terminal. Approving this stop confirms the push."
    return
  fi
  _run shipper "Ship $TASK. The user confirmed the push at the pre-ship stop."
}

# ---------- the MR review route (ADR 0003) ----------
# decide_review: like decide, for an MR review. There's no branch, plan, fix
# round or Duo round: the review reads the MR head in the review worktree,
# and its checks and findings never send work back to the implementer.
decide_review() {
  local iid="${TASK#mr-}" head src fp n
  head="$(_head)"

  STAGE=spec
  if [ ! -f "$DIR/requirements.md" ]; then _run requirements "Find the spec for $TASK, an MR review of !$iid."; return; fi
  src="$(_last_value "$DIR/requirements.md" "Spec source:" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
  if [ -z "$src" ]; then
    _unreadable spec "$REL/requirements.md has no 'Spec source:' line. The requirements agent must write where the spec came from."; return
  fi
  if [ "$(tr '[:upper:]' '[:lower:]' <<<"$src")" = none ]; then
    fp="$(_checksum requirements.md)"
    if _approved spec "$fp"; then
      _run requirements "The user approved the MR description as the spec for $TASK. Write the ACs from it, with Spec source: MR description (weak)."; return
    fi
    _stop spec "$fp" "No ClickUp task found for !$iid (see $REL/requirements.md). Reply with a ClickUp task id or the acceptance criteria, or approve reviewing against the MR description alone (a weak spec check)."
    return
  fi

  STAGE=focus   # moot once this head is reviewed
  n=0
  if [ "$(state_reviewed_sha "$TASK")" != "$head" ]; then
    local files
    if ! files="$(_review_files)"; then
      local target; target="$(state_target_branch "$TASK")"
      _unreadable focus "Can't count the MR's files: origin/${target:-$BASE_BRANCH} (its target branch) can't be read here. Run /review-mr $iid again to fetch it."; return
    fi
    n="$(printf '%s' "$files" | grep -c . || true)"
  fi
  if [ "$n" -gt "$MR_REVIEW_MAX_FILES" ]; then
    fp="$(_checksum @HEAD focus.md)"
    if ! _approved focus "$fp"; then
      local what="approve to review the $MR_REVIEW_MAX_FILES files with the most churn"
      [ -f "$DIR/focus.md" ] && what="approve to review what $REL/focus.md lists"
      _stop focus "$fp" "!$iid changes $n files (more than MR_REVIEW_MAX_FILES=$MR_REVIEW_MAX_FILES, not counting lockfiles and generated files). Reply with what to review, or $what."
      return
    fi
  fi

  STAGE=checks
  if [ "$(_field verification.md Commit)" != "$head" ]; then
    _run verifier "Run the checks for $TASK in its review worktree. Failures are findings, not fixes."; return
  fi
  case "$(_field verification.md Result)" in
    PASS|FAIL) ;;
    *) _unreadable verify "$REL/verification.md has no 'Result: PASS|FAIL' line."; return ;;
  esac

  STAGE=review
  if [ "$(state_reviewed_sha "$TASK")" != "$head" ]; then _run reviewer "Review $TASK."; return; fi
  if [ ! -f "$DIR/code-review.md" ]; then
    _unreadable review "The MR head was reviewed, but there's no $REL/code-review.md. Run the reviewer again by hand."; return
  fi

  STAGE=findings
  local id d r th st rp pending=() unposted=() unreplied=() posted=0 debt=0 skipped=0 verified=0
  while IFS=$'\037' read -r id d r th st rp; do
    case "$d" in
      post) if [ -z "$th" ]; then unposted+=("$id"); continue; fi
            posted=$((posted + 1))
            if [ "$st" = verified ]; then verified=$((verified + 1)); [ -n "$rp" ] || unreplied+=("$id"); fi ;;
      debt) debt=$((debt + 1)) ;;
      skip) skipped=$((skipped + 1)) ;;
      *) pending+=("$id") ;;
    esac
  done < <(findings_list "$DIR/code-review.md")
  fp="$(_checksum @nothreads:code-review.md)"
  if ! _approved findings "$fp"; then
    [ "${#pending[@]}" -gt 0 ] && APPROVE_BLOCK="Decide ${pending[*]} first (post, debt or skip); approval can't decide for you."
    _stop findings "$fp" "Review $REL/code-review.md: mark each finding post, debt (kept in $REL/tech-debt.md) or skip. Approving posts the ones marked post, each with your confirmation."
    return
  fi

  STAGE=post
  if [ "${#unposted[@]}" -gt 0 ]; then
    _run reviewer "Post the findings marked post for $TASK: ${unposted[*]}."; return
  fi
  if [ "${#unreplied[@]}" -gt 0 ]; then
    _run reviewer "Reply on the threads of the findings verified for $TASK: ${unreplied[*]}. Don't resolve them."; return
  fi
  local also=""; [ "$verified" -gt 0 ] && also=", $verified verified since posting"
  _end "Review of !$iid done at $(_head --short): $posted posted, $debt parked in $REL/tech-debt.md, $skipped skipped$also. Run /review-mr $iid again after the author pushes."
}

# _review_files: the files the MR changes, from where it left its target branch
# to its head, without the ones MR_REVIEW_SKIP_PATTERN matches. On a re-review,
# only the files changed since the reviewed head. Returns 1 when the target
# branch can't be read.
_review_files() {
  local base target reviewed
  target="$(state_target_branch "$TASK")"
  reviewed="$(state_reviewed_sha "$TASK")"
  if [ -n "$reviewed" ] && [ "$reviewed" != "$(_head)" ] && git merge-base --is-ancestor "$reviewed" "$(_head)" 2>/dev/null; then
    base="$reviewed"
  else
    base="$(git merge-base "refs/remotes/origin/${target:-$BASE_BRANCH}" "$(_head)" 2>/dev/null)" || return 1
  fi
  git -C "$HEAD_DIR" diff --name-only "$base" HEAD | grep -Ev "$MR_REVIEW_SKIP_PATTERN" || true
}

# check_duo: the MR is open. /fetch-review moves the Duo round on; each round
# is triaged, re-verified, and pushed and replied to, with one stop before the
# push when there are ASK threads or commits to push.
check_duo() {
  local round triage triage_round replied asks head pushed fp why=""
  round="$(state_review_round "$TASK")"
  if [ "$round" = 0 ]; then _end "MR open. Run /fetch-review $TASK after Duo has reviewed it."; return; fi
  if ! triage="$(round_triage "$DIR/review-triage.md" 2>&1)"; then
    _unreadable duo "$REL/$triage. The review-responder must write it from the review-triage.md template in its instructions."; return
  fi
  read -r triage_round replied asks <<< "$triage"
  if [ "$triage_round" -lt "$round" ]; then
    RESET_ROUNDS=1; _run review-responder "Triage $TASK."; return
  fi
  if [ "$replied" = yes ]; then
    _end "Duo round $round is answered. Run /fetch-review $TASK after the next review."; return
  fi

  check_verified "Re-verify" || return

  head="$(git rev-parse HEAD)"
  pushed="$(git rev-parse --verify -q "refs/remotes/origin/$(state_branch "$TASK")" || true)"
  if [ "$asks" -gt 0 ] || [ "$pushed" != "$head" ]; then
    fp="$(_checksum @HEAD review-triage.md)"
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
  local w _
  read -r w _ <<< "$(_last_value "$DIR/$1" "$2:")"
  printf '%s\n' "$w"
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
        PASS) [ "$(gate_verified "$TASK")" = "$head" ] && return 0 ;;
        *) _unreadable verify "$REL/verification.md has no 'Result: PASS|FAIL' line."; return 1 ;;
      esac
    fi
  fi
  _run verifier "$verb $TASK."; return 1
}

# check_review: the review at HEAD is settled, or set a run/stop and return 1.
# Open quick fixes go back to the implementer; a finding with no decision, or
# a fix routed to requirements or re-plan, stops for the user. Approving that
# stop sends the run to the furthest-back route.
check_review() {
  local head id d r th st rp pending=() req=() replan=() quick=() fp
  head="$(git rev-parse HEAD)"
  if [ "$(state_reviewed_sha "$TASK")" != "$head" ]; then _run reviewer "Review $TASK."; return 1; fi
  if [ ! -f "$DIR/code-review.md" ]; then
    _unreadable review "HEAD was reviewed, but there's no $REL/code-review.md. Run the reviewer again by hand."; return 1
  fi
  while IFS=$'\037' read -r id d r th st rp; do
    case "$d" in
      fix) [ "$st" = open ] || continue
           case "$r" in quick) quick+=("$id") ;; requirements) req+=("$id") ;; re-plan) replan+=("$id") ;; *) pending+=("$id") ;; esac ;;
      debt|skip) ;;
      *) pending+=("$id") ;;
    esac
  done < <(findings_list "$DIR/code-review.md")

  if [ $(( ${#pending[@]} + ${#req[@]} + ${#replan[@]} )) -gt 0 ]; then
    fp="$(_checksum code-review.md)"
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
  round="$(_status_value "Fix round")"; round="${round%%/*}"; round="${round:-0}"; key="$(_status_value "Fix key")"
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
        evidence/APPROVED mr.md auto-decisions.md review-triage.md state.env @verified)
[ "$KIND" = MR_REVIEW ] && INPUTS=(@HEAD requirements.md focus.md verification.md code-review.md tech-debt.md state.env)
check_stall() {
  [ "$VERB" = run ] || return 0
  INPUTS_FP="$(_checksum "${INPUTS[@]}")"
  LAST_RUN="run $WHAT $TEXT"; LAST_RUN_FP="$INPUTS_FP"
  [ "$LAST_RUN" = "$(_status_value "Last run")" ] && [ "$INPUTS_FP" = "$(_status_value "Last run inputs")" ] || return 0
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
    "none of its Stop flags is \"yes\", and it has $MAX_PLAN_SLICES or fewer slices." \
    "Plan: stop only on requirement gaps, a migration, a feature flag, another team's work, or more than $MAX_PLAN_SLICES slices (ADR 0001)."
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
    echo "Last run: ${LAST_RUN:-$(_status_value "Last run")}"
    echo "Last run inputs: ${LAST_RUN_FP:-$(_status_value "Last run inputs")}"
    echo "Pending stop: $pending"
    echo "Fix round: $NEW_ROUND/$MAX_AUTO_FIX_ROUNDS"
    echo "Fix key: $NEW_KEY"
    echo "Plan accepted: ${PLAN_ACCEPTED:-$(_status_value "Plan accepted")}"
    if [ -n "$APPROVALS" ]; then sed 's/^/Approved /' <<<"$APPROVALS"; fi
  } > "$STATUS.tmp"
  mv "$STATUS.tmp" "$STATUS"
}

# ---------- run.log writer ----------
# One line per decision printed and per approval recorded (ADR 0002), only ever
# appended: "<UTC time> <run|stop|end|approve> <agent or stop id, - for end>
# round=<n>/<max> head=<short HEAD>". Not one of the run's INPUTS, so writing it
# never hides a stalled stage.
log_run() {
  printf '%s %s %s round=%s/%s head=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "${2:--}" \
    "$NEW_ROUND" "$MAX_AUTO_FIX_ROUNDS" "$(_head --short 2>/dev/null || echo none)" >> "$DIR/run.log"
}

# Approvals: one fingerprint per stop id.
# A plain list of "<stop-id>: <fingerprint>" lines: bash 3.2 (macOS) has no
# associative arrays.
APPROVALS="$(grep '^Approved [a-z-]*: ' "$STATUS" 2>/dev/null | sed 's/^Approved //')"
_drop_approval() { APPROVALS="$(grep -v "^$1: " <<<"$APPROVALS")"; }
_set_approval() { _drop_approval "$1"; APPROVALS="${APPROVALS:+$APPROVALS$'\n'}$1: $2"; }

PLAN_ACCEPTED=""; AUTO_PLAN=""; FIX_KEY=""; LAST_RUN=""; LAST_RUN_FP=""; RESET_ROUNDS=""; APPROVE_BLOCK=""
if [ "$KIND" = MR_REVIEW ]; then decide_review; else decide; fi
apply_fix_round
check_stall

if [ "$CMD" = approve ]; then
  pending="$(_status_value "Pending stop")"
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
    PLAN_ACCEPTED="$(_checksum @unticked:plan.md) $(_checksum requirements.md)"   # keep the plan for the new requirements
  fi
  LINE="$(_status_value "Last decision")"
  write_status
  log_run approve "$WHAT"
  echo "Approved the $WHAT stop."
  exit 0
fi

case "$VERB" in
  run)  LINE="run $WHAT $TEXT" ;;
  stop) LINE="stop $WHAT $TEXT" ;;
  end)  LINE="end $TEXT" ;;
esac
write_status
log_run "$VERB" "$WHAT"
[ -n "$AUTO_PLAN" ] && record_auto_plan "$AUTO_PLAN"
echo "$LINE"
