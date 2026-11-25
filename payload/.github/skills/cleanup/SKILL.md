---
name: cleanup
description: "Clean up a finished pipeline task once its MR is merged or closed: delete its local branch (merged only), its .work/ folder and, for an MR review, its review worktree. --finished does every finished task. Use only when the user runs /cleanup."
argument-hint: "<task-id | mr-iid> [--force] [--drop-debt] | --finished"
disable-model-invocation: true
---
# Clean up a finished task

The user gave a task id (`86c1abcde`, or `mr-142` for an MR review), maybe followed by `--force` or `--drop-debt`, or just `--finished`. If nothing was given, ask for a task id or `--finished` and stop.

1. Run `scripts/agent/cleanup-task.sh <what the user gave>`, passing `--force` and `--drop-debt` only when the user typed them. Never add either yourself: `--force` skips the check that the MR is merged or closed, and `--drop-debt` lets parked debt go.
2. Pass on its message and end your turn. Don't run anything else, and don't start an auto run: this works the same in any agent.

The script refuses, and changes nothing, when the MR is still open, the task has no MR, glab can't tell the MR's state, the user is on the task's branch or has uncommitted changes, or tech-debt.md still has parked debt. Its message says what to do. It never touches the remote.
