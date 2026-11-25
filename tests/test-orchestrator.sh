#!/usr/bin/env bash
# Checks the orchestrator's file (pipeline.agent.md) against the auto run's
# contract: next-stage.sh's verbs and stop ids (ADR 0001, issue #4).
# Usage: tests/test-orchestrator.sh     (exit 0 = all passed)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
A="$ROOT/payload/.github/agents"
O="$A/pipeline.agent.md"
NS="$ROOT/payload/scripts/agent/next-stage.sh"
pass=0; fail=0
check() { if eval "$2"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; fi; }

[ -f "$O" ] || { echo "FAIL: $O is missing"; echo "passed=0 failed=1"; exit 1; }

# frontmatter: the lines between the file's first two "---" lines.
frontmatter() { awk 'NR == 1 && $0 == "---" { on = 1; next } on && $0 == "---" { exit } on' "$O"; }
# section <heading>: the lines under "## <heading>", up to the next "## ".
section() { awk -v h="## $1" '/^## / { on = ($0 == h); next } on' "$O"; }
# sec <heading> <ERE>: that section matches the pattern.
sec() { section "$1" | grep -qE -- "$2"; }

# ---------- frontmatter ----------
check "name: pipeline" 'frontmatter | grep -qx "name: pipeline"'
check "model: the cheapest model" 'frontmatter | grep -qx "model: '"'"'GPT-6 Luna'"'"'"'
check "tools: read, search, execute, agent, and no edit" 'frontmatter | grep -qx "tools: \[.read., .search., .execute., .agent.\]"'
check "no handoffs: it drives the stages as subagents" '! frontmatter | grep -q "^handoffs:"'

# ---------- the loop ----------
check "runs next-stage.sh <task-id> and acts on the one line" 'sec "The loop" "scripts/agent/next-stage.sh <task-id>\`"'
check "run: the prompt goes on word for word" 'sec "The loop" "^- \`run <agent> <prompt>\`" && sec "The loop" "word for word"'
check "run: calls the stage by name, never vscode-agent-<hash>" 'sec "The loop" "by name" && sec "The loop" "vscode-agent-"'
check "run: names the stage's model from its model: line on every call" 'sec "The loop" "\`model:\` line" && sec "The loop" "every call"'
check "run: one progress line with the stage's Result line" 'sec "The loop" "▶ <agent>: <its \`\*\*Result:\*\*\` line>"'
check "run: one stage at a time" 'sec "The loop" "one at a time"'
check "run: no loop guard of its own; the stalled stop covers it" 'sec "The loop" "\`stalled\`"'
check "exit 1: pass on the script's message" 'sec "The loop" "exits 1"'

# ---------- stops ----------
check "stop: shows the DECISION NEEDED block, then ends the turn" 'sec "Stops" "^⏸ DECISION NEEDED: <stop-id>" && sec "Stops" "end your turn"'
check "stop: the reason word for word, with the files it names" 'sec "Stops" "<reason, word for word>"'
check "stop: the last stage's Result line, the only place a stalled stage says why" 'sec "Stops" "Last stage result: <" && sec "Stops" "stalled"'
check "stop: lists the replies it accepts" 'sec "Stops" "^- \`approve\`" && sec "Stops" "^- anything else"'
check "approval: only a reply that is nothing but an approval" 'sec "Answering a stop" "nothing but an approval" && sec "Answering a stop" "\`lgtm\`"'
check "approval: runs next-stage.sh <task-id> approve, then next-stage.sh again" 'sec "Answering a stop" "\`scripts/agent/next-stage.sh <task-id> approve\`" && sec "Answering a stop" "then run \`scripts/agent/next-stage.sh <task-id>\`"'
check "approval refused: its message word for word and the stop again" 'sec "Answering a stop" "exits 1" && sec "Answering a stop" "word for word" && sec "Answering a stop" "same stop block again"'
check "never approves for the user" 'sec "Answering a stop" "Never run .approve. without"'

# ---------- feedback: every stop the router raises has a stage to send it to ----------
# stop_ids: each stop id next-stage.sh can print (from its _stop and _unreadable calls).
stop_ids() { grep -oE '_(stop|unreadable) [a-z-]+ ' "$NS" | awk '{ print $2 }' | sort -u; }
# feedback_agent <stop-id>: the agent in that stop's row of the Feedback table.
feedback_agent() { section "Feedback" | awk -F'|' -v id="\`$1\`" '{ c = $2; gsub(/^ +| +$/, "", c) } c == id { print $3 }' | grep -oE '[a-z-]+' | head -n1; }
check "the router raises stops (the cross-check reads them)" '[ "$(stop_ids | wc -l)" -ge 9 ]'
for id in $(stop_ids); do
  check "feedback: the $id stop has a row" '[ -n "$(feedback_agent $id)" ]'
done
# feedback_agents_exist: each row's agent has an agent file (stalled names no fixed agent).
feedback_agents_exist() { local id a; for id in $(stop_ids); do [ "$id" = stalled ] && continue; a="$(feedback_agent "$id")"; [ -f "$A/$a.agent.md" ] || return 1; done; }
check "feedback: every agent in the table exists" 'feedback_agents_exist'
check "feedback: the stalled stop goes back to the agent its reason names" 'section Feedback | grep -E "^\| \`stalled\`" | grep -q "named at the start of the reason"'
check "feedback: pre-ship goes to evidence, or the shipper writing mr.md" 'section Feedback | grep -E "^\| \`pre-ship\`" | grep -q evidence && sec Feedback "Write mr.md for <task-id>. Don.t push or create the MR."'
check "feedback: the prompt carries the reply word for word" 'sec Feedback "AUTO RUN. The user replied at the <stop-id> stop for <task-id>: \"<reply, word for word>\""'

# ---------- the docs' stop table matches the router ----------
DOC="$ROOT/payload/docs/agent-pipeline.md"
# unapprovable_row: the doc's row for stops no approval passes (an unreadable file).
unapprovable_row() { grep -E '^\| .*\| .*No approval passes it' "$DOC"; }
for id in $(grep -oE '_unreadable [a-z-]+ ' "$NS" | awk '{ print $2 }' | sort -u); do
  check "docs: the $id stop is listed as one no approval passes" 'unapprovable_row | cut -d"|" -f2 | grep -q "\`$id\`"'
done
check "docs: the run also ends when a Duo round is answered" 'grep -q "^The run ends when the MR is open.*Duo round is answered" "$DOC"'
# diagram: the first fenced block in the guide, its pipeline diagram (#56).
diagram() { awk '/^```/ { if (on) exit; on = 1; next } on' "$DOC"; }
for id in $(grep -oE '_stop [a-z-]+ ' "$NS" | awk '{ print $2 }' | sort -u); do
  check "diagram: shows the $id stop" 'diagram | grep -qE "⏸ $id:| $id \("'   # "⏸ plan: …", or "stalled (…)" in the key
done
for a in $(sed -n 's/^STAGE_AGENTS="\(.*\)"$/\1/p' "$NS"); do
  check "diagram: shows the $a stage" 'diagram | grep -qw "$a"'
done
check "diagram: names the orchestrator and the router" 'diagram | grep -q "pipeline agent" && diagram | grep -q "next-stage.sh"'
check "diagram: the fail and quick-fix loops back to the implementer" 'diagram | grep -q "fail" && diagram | grep -q "quick fix"'
check "diagram: the Duo round loops from /fetch-review" '[ "$(diagram | grep -c "/fetch-review")" -ge 2 ]'
check "feedback: then next-stage.sh again" 'sec Feedback "run \`scripts/agent/next-stage.sh <task-id>\` again"'
check "retry or continue: next-stage.sh again, nothing sent to a stage" 'sec Feedback "\`retry\` or \`continue\`"'

# ---------- starting and resuming ----------
check "start: /start-task hands over, then the loop" 'sec "Starting a run" "/start-task <task-id> <slug>"'
check "resume: /fetch-review, or Run/Continue <task-id>" 'sec "Starting a run" "/fetch-review <task-id>" && sec "Starting a run" "\`Run <task-id>\` or \`Continue <task-id>\`"'
check "start: /review-mr starts an MR review, the loop runs on mr-<iid>" 'sec "Starting a run" "/review-mr <iid> \[clickup-id\]" && sec "Starting a run" "mr-<iid>"'
check "warning: Auto in the model picker cancels pinned models, once per run" 'sec "Starting a run" "\*\*Auto\*\*" && sec "Starting a run" "Copilot Free" && sec "Starting a run" "once"'
check "warning: it doesn't block the run" 'sec "Starting a run" "don.t stop"'

# ---------- rules ----------
check "rules: never writes product code or any file" 'sec "Rules" "never write product code" && sec "Rules" "any file"'
check "rules: status.md is the script's, read only" 'sec "Rules" "status.md" && sec "Rules" "only read"'
check "rules: no auto-decisions of its own" 'sec "Rules" "auto-decisions.md"'
check "rules: publishing stays with the stages" 'sec "Rules" "create-mr.sh" && sec "Rules" "push-branch.sh"'
check "rules: no stage work of its own" 'sec "Rules" "never do a stage.s work"'

# ---------- the skills hand an auto run over to the orchestrator ----------
SK="$ROOT/payload/.github/skills"
check "/start-task: the pipeline agent starts the auto run" 'grep -q "If you are the \*\*pipeline\*\* agent, start the auto run" "$SK/start-task/SKILL.md"'
check "/fetch-review: the pipeline agent continues the auto run" 'grep -q "If you are the \*\*pipeline\*\* agent, continue the auto run" "$SK/fetch-review/SKILL.md"'
check "/fetch-review: the round limit comes before the hand-over" 'awk "/round limit/ { r = NR } /pipeline\*\* agent/ { p = NR } END { exit !(r && p && r < p) }" "$SK/fetch-review/SKILL.md"'
# stops_before <skill> <n>: n script steps say "If it fails … pass on its message
# and end your turn here", all before the pipeline hand-over, so no failure
# reaches the loop. ("Stop" is kept for the auto run's stops.)
stops_before() { awk '/If it fails.*pass on its message and end your turn here/ { if (!p) n++ } /pipeline\*\* agent/ { p = 1 } END { exit !(p && n == '"$2"') }' "$SK/$1/SKILL.md"; }
check "/start-task: either script failing stops before the hand-over" 'stops_before start-task 2'
check "/fetch-review: the fetch failing stops before the hand-over" 'stops_before fetch-review 1'
check "/fetch-review: takes an optional --force" 'grep -qx "argument-hint: \"<clickup-task-id> \[--force\]\"" "$SK/fetch-review/SKILL.md"'
check "/fetch-review: passes --force on only when the user typed it" 'grep -q "fetch-duo-review.sh <task-id> \[--force\]\`.*only when the user typed it" "$SK/fetch-review/SKILL.md" && grep -q "Never add \`--force\` yourself" "$SK/fetch-review/SKILL.md"'
check "/fetch-review: the round limit isn't an auto-run stop: no decision block, no router" 'grep "round limit" "$SK/fetch-review/SKILL.md" | grep "isn.t an auto-run stop" | grep "DECISION NEEDED" | grep -q "don.t run \`next-stage.sh\`"'
check "/fetch-review: at the round limit, the exact --force command, task id first" 'grep "round limit" "$SK/fetch-review/SKILL.md" | grep -q "\`/fetch-review <task-id> --force\` (the task id first)"'
check "/fetch-review: a failure doesn't go on to step 2" 'grep -q "end your turn here, without step 2" "$SK/fetch-review/SKILL.md"'
check "/review-mr: the pipeline agent starts the auto run on mr-<iid>" 'grep -q "If you are the \*\*pipeline\*\* agent, start the auto run for \`mr-<iid>\`" "$SK/review-mr/SKILL.md"'
check "/review-mr: the script failing stops before the hand-over" 'stops_before review-mr 1'
check "/review-mr: takes an iid and an optional ClickUp id, or --done" 'grep -qx "argument-hint: \"<mr-iid> \[clickup-task-id | --done\]\"" "$SK/review-mr/SKILL.md"'
check "/review-mr --done: runs start-review.sh --done and ends, no auto run" 'grep -q "start-review.sh <iid> --done" "$SK/review-mr/SKILL.md" && grep "\-\-done" "$SK/review-mr/SKILL.md" | grep -q "don.t start the auto run"'
check "/review-mr: its description names the auto run" 'grep "^description:" "$SK/review-mr/SKILL.md" | grep -q "pipeline agent, start the auto run"'
check "/start-task: its description names the auto run" 'grep "^description:" "$SK/start-task/SKILL.md" | grep -q "pipeline agent, start the auto run"'
check "/fetch-review: its description names the auto run" 'grep "^description:" "$SK/fetch-review/SKILL.md" | grep -q "pipeline agent, resume the auto run"'
# In any other agent, the skills set up and point to the pipeline agent, not to a
# stage agent (#129): manual mode starts by picking the stage agent first.
check "/start-task: in another agent, the hand-off names the pipeline agent and Run" 'grep -q "^   > \*\*Next:\*\* pick the \*\*pipeline\*\* agent and say \`Run <task-id>\`\.$" "$SK/start-task/SKILL.md"'
check "/start-task: the hand-off no longer sends you to the requirements agent" '! grep -q "pick the \*\*requirements\*\* agent" "$SK/start-task/SKILL.md"'
check "/start-task: the requirements agent still goes on by itself" 'grep -q "If you are the \*\*requirements\*\* agent, continue with your normal steps now" "$SK/start-task/SKILL.md"'
check "/fetch-review: in another agent, the hand-off names the pipeline agent and Continue" 'grep -q "^   > \*\*Next:\*\* pick the \*\*pipeline\*\* agent and say \`Continue <task-id>\`\.$" "$SK/fetch-review/SKILL.md"'
check "/fetch-review: the hand-off no longer sends you to the review-responder agent" '! grep -q "pick the \*\*review-responder\*\* agent" "$SK/fetch-review/SKILL.md"'
check "/fetch-review: the review-responder agent still goes on by itself" 'grep -q "If you are the \*\*review-responder\*\* agent, continue with your \"Triage and fix\" steps" "$SK/fetch-review/SKILL.md"'
check "/start-task: its description names the pipeline hand-off" 'grep "^description:" "$SK/start-task/SKILL.md" | grep -q "point you to the pipeline agent"'
check "/fetch-review: its description names the pipeline hand-off" 'grep "^description:" "$SK/fetch-review/SKILL.md" | grep -q "point you to the pipeline agent"'

# ---------- the MR review route is documented (ADR 0003, #88) ----------
# guide_sec <heading> <ERE>: the guide's "## <heading>" section matches.
# (The section is read into a variable first: grep -q stopping early would
# break awk's pipe, which pipefail turns into a random failure.)
guide_sec() { local t; t="$(awk -v h="## $1" '/^```/ { f = !f } !f && /^## / { on = ($0 == h); next } on' "$DOC")"; grep -qE -- "$2" <<<"$t"; }
G="MR review (a teammate's MR)"
check "guide: an MR review section" 'grep -qx "## $G" "$DOC"'
check "guide: how it starts, the iid explained" 'guide_sec "$G" "/review-mr <iid> \[clickup-id\]" && guide_sec "$G" "!142"'
check "guide: the stages and its three stops" 'guide_sec "$G" "\`spec\`" && guide_sec "$G" "\`focus\`" && guide_sec "$G" "\`findings\`"'
check "guide: read-only, in a review worktree" 'guide_sec "$G" "read-only" && guide_sec "$G" "\.git/pipeline-reviews/mr-<iid>"'
check "guide: posting, each confirmed, with the header" 'guide_sec "$G" "post-review-thread\.sh" && guide_sec "$G" "\[pipeline review\]"'
check "guide: re-review, never resolving a thread" 'guide_sec "$G" "[Rr]e-review" && guide_sec "$G" "never resolves"'
check "guide: --done and the doctor warning" 'guide_sec "$G" "/review-mr <iid> --done" && guide_sec "$G" "doctor\.sh"'
check "guide: the new settings" 'guide_sec "$G" "INSTALL_CMD" && guide_sec "$G" "MR_REVIEW_MAX_FILES" && guide_sec "$G" "MR_REVIEW_SKIP_PATTERN"'
W="What's in here"
check "guide: the skill is listed in What's in here" 'guide_sec "$W" "skills/review-mr/SKILL\.md"'
check "guide: the guard table has the MR review rules" 'guide_sec "Hooks (enforced rules)" "pipeline-reviews" && guide_sec "Hooks (enforced rules)" "post-review-thread\.sh"'
README="$ROOT/README.md"
for f in "$ROOT"/tests/test-*.sh; do
  check "README: the Development list names $(basename "$f")" 'grep -q "^tests/$(basename "$f") " "$README"'
done
check "guide: says which ClickUp writes the guard denies in an MR review" 'guide_sec "$G" "only for an .mr-<iid>. task id"'
check "README: a Review a teammate's MR section with /review-mr" 'grep -qx "## Review a teammate.s MR" "$README" && grep -q "/review-mr <iid>" <<<"$(awk "/^## Review a teammate/ { on = 1; next } /^## / { on = 0 } on" "$README")"'
M="Manual mode (fallback)"
check "guide: manual mode picks requirements before /start-task" 'guide_sec "$M" "^\| 1 \| \*\*requirements\*\*, then \`/start-task 86c1abcde invoice-export\` \|"'
check "guide: manual mode picks review-responder before /fetch-review" 'guide_sec "$M" "\| \*\*review-responder\*\*, then \`/fetch-review 86c1abcde\` \|"'
check "guide: manual mode says the skills point anywhere else to the pipeline agent" 'guide_sec "$M" "In any other agent.*pipeline"'
check "guide: the skills table names the pipeline hand-off" 'guide_sec "$W" "skills/start-task/SKILL\.md.*pipeline\*\* agent" && guide_sec "$W" "skills/fetch-review/SKILL\.md.*pipeline\*\* agent"'
check "rules for every agent: an MR review is read-only" 'grep -q "/review-mr" "$ROOT/payload/pipeline-instructions.md" && grep -q "read-only" "$ROOT/payload/pipeline-instructions.md"'

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
