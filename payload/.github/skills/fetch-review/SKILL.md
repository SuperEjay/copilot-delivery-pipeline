---
name: fetch-review
description: "Fetch GitLab Duo's latest unresolved MR review for a pipeline task and hand over to the review-responder agent. Use only when the user runs /fetch-review."
argument-hint: "<clickup-task-id> [--force]"
disable-model-invocation: true
---
# Fetch the Duo review

The user gave a task id, and maybe `--force` after it. If the task id is missing, ask for it and stop.

1. Run `scripts/agent/fetch-duo-review.sh <task-id> [--force]`, with `--force` only when the user typed it after the task id. Never add `--force` yourself. If it fails, pass on its message and stop. At the review-round limit, the user decides whether to continue with `/fetch-review <task-id> --force`; the round limit is not a stop, so even as the **pipeline** agent show no `⏸ DECISION NEEDED` block and don't run `next-stage.sh`.
2. If you are the **pipeline** agent, continue the auto run for `<task-id>`: follow your loop now.
   If you are the **review-responder** agent, continue with your "Triage and fix" steps from step 2.
   Otherwise reply with exactly this, filled in, and stop:
   > Fetched `<n>` unresolved thread(s) into `.work/<task-id>/review.json`.
   > **Next:** pick the **review-responder** agent and say `Triage <task-id>`.
