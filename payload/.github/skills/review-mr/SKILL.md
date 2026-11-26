---
name: review-mr
description: "Start a read-only review of an existing GitLab MR (ADR 0003): check the MR out into a review worktree and set up its work folder, then, in the pipeline agent, start the auto run. Use only when the user runs /review-mr."
argument-hint: "<mr-iid> [clickup-task-id | --done]"
disable-model-invocation: true
---
# Review an MR

The user gave an MR iid (the `142` in `!142`), and maybe a ClickUp task id after it, for an MR that doesn't name its task. If the iid is missing, ask for it and stop.

**`--done` after the iid:** the review is finished (the MR is merged or closed). Run `scripts/agent/start-review.sh <iid> --done`, pass on its message and end your turn: don't start the auto run. Once the MR is merged or closed, it removes the review worktree and `.work/mr-<iid>/`; while the MR is open it refuses (to drop a review you no longer need, the user runs `/cleanup mr-<iid> --force`).

1. Run `scripts/agent/start-review.sh <iid> [clickup-task-id]`, with the ClickUp id only when the user gave one. If it fails (for example, the MR is merged or closed, or glab can't read it), pass on its message and end your turn here.
2. If you are the **pipeline** agent, start the auto run for `mr-<iid>`: follow your loop now, with `mr-<iid>` as the task id.
   Otherwise reply with exactly this, filled in, and stop:
   > MR `!<iid>` is checked out for review. An MR review runs only as an auto run.
   > **Next:** switch the agent picker to **pipeline**, then say `Run mr-<iid>` there.
   Never start the **pipeline** agent as a subagent, even if you can: run as a subagent, the guard refuses it `next-stage.sh` and it can't start the stage agents. Only the user switches to it.

Never change the MR's code, in the review worktree or anywhere else: an MR review is read-only.
