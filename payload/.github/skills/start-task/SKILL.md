---
name: start-task
description: "Start a ClickUp task in the delivery pipeline: create the branch and work folder, fetch the task, then hand over to the requirements agent or, in the pipeline agent, start the auto run. Use only when the user runs /start-task."
argument-hint: "<clickup-task-id> <short-slug> | <clickup-task-id> --mr <iid> | <clickup-task-id> --branch <branch>"
disable-model-invocation: true
---
# Start a task

The user gave a ClickUp task id and a short kebab-case slug (e.g. `86c1abcde invoice-export`). If either is missing, ask for it and stop.

To fix work they started outside the pipeline (ADR 0004), they give `--mr <iid>` (their own open MR) or `--branch <branch>` in place of the slug, e.g. `86c1abcde --mr 142`. Pass those on to the script exactly as given; the task then runs the whole delivery route on that branch.

1. Run `scripts/agent/start-task.sh <task-id> <slug>` (or `<task-id> --mr <iid>`, `<task-id> --branch <branch>`). If it fails (for example, uncommitted changes), pass on its message and end your turn here.
2. Run `scripts/agent/clickup.sh fetch <task-id>`. If it fails (token, access, wrong id), pass on its message and end your turn here.
3. If you are the **pipeline** agent, start the auto run for `<task-id>`: follow your loop now.
   If you are the **requirements** agent, continue with your normal steps now.
   Otherwise reply with exactly this, filled in, and stop:
   > Task `<task-id>` is set up on branch `<branch>` and fetched to `.work/<task-id>/clickup/task.md`.
   > **Next:** pick the **requirements** agent and say `Analyse <task-id>`.

Don't analyse requirements yourself unless you are the requirements agent: that agent runs on the model chosen for that job.
