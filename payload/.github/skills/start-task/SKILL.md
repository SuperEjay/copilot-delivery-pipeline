---
name: start-task
description: "Start a ClickUp task in the delivery pipeline: create the branch and work folder, fetch the task, then hand over to the requirements agent. Use only when the user runs /start-task."
argument-hint: "<clickup-task-id> <short-slug>"
disable-model-invocation: true
---
# Start a task

The user gave a ClickUp task id and a short kebab-case slug (e.g. `86c1abcde invoice-export`). If either is missing, ask for it and stop.

1. Run `scripts/agent/start-task.sh <task-id> <slug>`. If it reports uncommitted changes, stop and tell the user.
2. Run `scripts/agent/clickup.sh fetch <task-id>`. If it fails (token, access, wrong id), stop and pass on the script's message.
3. If you are the **requirements** agent, continue with your normal steps now.
   Otherwise reply with exactly this, filled in, and stop:
   > Task `<task-id>` is set up on branch `<branch>` and fetched to `.work/<task-id>/clickup/task.md`.
   > **Next:** pick the **requirements** agent and say `Analyse <task-id>`.

Don't analyse requirements yourself unless you are the requirements agent: that agent runs on the model chosen for that job.
