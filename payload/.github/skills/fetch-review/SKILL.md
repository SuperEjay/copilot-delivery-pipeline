---
name: fetch-review
description: "Fetch GitLab Duo's latest unresolved MR review for a pipeline task, then, in the pipeline agent, resume the auto run. The review-responder agent goes on with its triage; any other agent will point you to the pipeline agent. Use only when the user runs /fetch-review."
argument-hint: "<clickup-task-id> [--force]"
disable-model-invocation: true
---
# Fetch the Duo review

The user gave a task id, and maybe `--force` after it. If the task id is missing, ask for it and stop.

1. Run `scripts/agent/fetch-duo-review.sh <task-id> [--force]`, with `--force` only when the user typed it after the task id. Never add `--force` yourself. If it fails, pass on its message and end your turn here, without step 2. At the review-round limit it fails too: then also tell the user they can go on with `/fetch-review <task-id> --force` (the task id first). That isn't an auto-run stop: even as the **pipeline** agent, show no `⏸ DECISION NEEDED` block and don't run `next-stage.sh`.
2. If you are the **pipeline** agent, continue the auto run for `<task-id>`: follow your loop now.
   If you are the **review-responder** agent, continue with your "Triage and fix" steps from step 2.
   Otherwise reply with exactly this, filled in, and stop:
   > Fetched `<n>` unresolved thread(s) into `.work/<task-id>/review.json`.
   > **Next:** switch the agent picker to **pipeline**, then say `Continue <task-id>` there.
   Never start the **pipeline** agent as a subagent, even if you can: run as a subagent, the guard refuses it `next-stage.sh` and it can't start the stage agents. Only the user switches to it.
