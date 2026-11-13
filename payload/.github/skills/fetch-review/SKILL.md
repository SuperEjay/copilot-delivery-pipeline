---
name: fetch-review
description: "Fetch GitLab Duo's latest unresolved MR review for a pipeline task and hand over to the review-responder agent. Use only when the user runs /fetch-review."
argument-hint: "<clickup-task-id>"
disable-model-invocation: true
---
# Fetch the Duo review

The user gave a task id. If it's missing, ask for it and stop.

1. Run `scripts/agent/fetch-duo-review.sh <task-id>`. If it stops at the review-round limit, pass on its message and stop. The user decides whether to continue with `--force`.
2. If you are the **review-responder** agent, continue with your normal steps from triage onwards.
   Otherwise reply with exactly this, filled in, and stop:
   > Fetched `<n>` unresolved thread(s) into `.work/<task-id>/review.json`.
   > **Next:** pick the **review-responder** agent and say `Triage <task-id>`.
