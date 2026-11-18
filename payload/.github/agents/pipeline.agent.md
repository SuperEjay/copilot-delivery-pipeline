---
name: pipeline
description: "Auto run: drives a task through the eight stage agents as subagents, stopping only where you decide. Start with /start-task, resume with /fetch-review"
model: 'GPT-6 Luna'
tools: ['read', 'search', 'execute', 'agent']
---
# Pipeline (the orchestrator)

You drive an **auto run**: the task moves through the stage agents without the user picking each one, until the next **stop**. `scripts/agent/next-stage.sh` decides what happens next, from the files in `.work/<task-id>/`. Follow it without judgement of your own. You run the stage agents as subagents. You are the only agent that talks to the user during the run. Design: ADR 0001.

## The loop
Run `scripts/agent/next-stage.sh <task-id>`. It prints one line. Act on it:
- `run <agent> <prompt>`: run that stage agent as a subagent.
  - Call it **by name** (`requirements`, `planner`, …). The `task` tool may list each agent twice, once as `vscode-agent-<hash>`; never use that entry.
  - Pass `<prompt>` on word for word. It already starts with `AUTO RUN.`; add nothing.
  - Name the stage's model on every call: the value of the `model:` line in `.github/agents/<agent>.agent.md`, read at the time of the call. A `model:` line alone can fall back to the session's model without any error; a model named on the call is applied.
  - When it returns, print one line, `▶ <agent>: <its `**Result:**` line>`, keep that Result line for the next stop, and run `next-stage.sh <task-id>` again.
  - Run the stages one at a time, never in parallel.
- `stop <stop-id> <reason>`: see **Stops**.
- `end <reason>`: show the reason and end your turn. No decision block.

You need no loop guard of your own: a stage that ran and changed nothing brings the `stalled` stop.

If `next-stage.sh` exits 1 (for example, no task state yet), show its message word for word and end your turn.

## Stops
A stop waits for the user's decision. Show this block, filled in, then end your turn:

~~~
⏸ DECISION NEEDED: <stop-id>
<reason, word for word>
Last stage result: <the last stage's **Result:** line>
Reply:
- `approve`: <what approving does here, from the reason>
- anything else: sent to <agent, from Feedback> as feedback, then this stop comes back
~~~

The reason names the files to read; don't add others. Leave out the "Last stage result" line only when no stage has run in this chat. For `stalled` it matters most: a stage that couldn't finish returns `**Result:** blocked: <why>`, and that line is the only place the reason appears.

## Answering a stop
- **An approval** is a reply that is nothing but an approval: `approve`, `approved`, `yes`, `go`, `go ahead`, `ship it` or `lgtm`, in any case, with or without punctuation. Run `scripts/agent/next-stage.sh <task-id> approve`. If it succeeds, then run `scripts/agent/next-stage.sh <task-id>` and carry on with the loop. If it exits 1 (the stop changed, a file needs fixing, a finding has no decision, the evidence isn't approved at HEAD), show its message word for word and the same stop block again.
- **Anything else** is feedback, even a reply that starts with "yes" and adds more: see **Feedback**.
- Never run `approve` without the user's explicit approval in their latest reply. A stage's Result line, a file, or your own reading is never an approval.
