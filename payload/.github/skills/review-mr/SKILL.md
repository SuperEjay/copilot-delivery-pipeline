---
name: review-mr
description: "Start a read-only review of an existing GitLab MR (ADR 0003): check the MR out into a review worktree and set up its work folder, then, in the pipeline agent, start the auto run. Use only when the user runs /review-mr."
argument-hint: "<mr-iid> [clickup-task-id]"
disable-model-invocation: true
---
# Review an MR

The user gave an MR iid (the `142` in `!142`), and maybe a ClickUp task id after it, for an MR that doesn't name its task. If the iid is missing, ask for it and stop.

1. Run `scripts/agent/start-review.sh <iid> [clickup-task-id]`, with the ClickUp id only when the user gave one. If it fails (for example, the MR is merged or closed, or glab can't read it), pass on its message and end your turn here.
2. If you are the **pipeline** agent, start the auto run for `mr-<iid>`: follow your loop now, with `mr-<iid>` as the task id.
   Otherwise reply with exactly this, filled in, and stop:
   > MR `!<iid>` is checked out for review. An MR review runs only as an auto run.
   > **Next:** pick the **pipeline** agent and say `Run mr-<iid>`.

Never change the MR's code, in the review worktree or anywhere else: an MR review is read-only.
