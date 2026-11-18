---
status: proposed (accepted once the subagent spike passes)
---

# Auto run through an orchestrator and subagents

We want a task to move through the pipeline without the user picking the next agent and typing a phrase at every stage. The pipeline should **stop** only where a human decision is needed. A new `pipeline` agent (the **orchestrator**) runs each of the eight stage agents as a Copilot subagent. A deterministic script, `scripts/agent/next-stage.sh`, decides which stage runs next or whether to stop, from the files already in `.work/<task-id>/`. We do it this way for three reasons. Handoffs don't work in Copilot (Agent Host) sessions, and the Local harness that supports them is being removed in February 2027. Subagents keep each stage's pinned model and a fresh context window. And a script makes the stop rules testable instead of leaving them to a model's judgment.

## Stop rules

- **Requirements:** always stops. Misreading the ticket is the costliest mistake.
- **Plan:** stops only on requirement gaps, a migration, a feature flag, work for another team, or more than 6 slices.
- **Code review:** reviewer recommendations are accepted automatically and recorded as **auto-decisions**. It stops only for findings routed to `requirements` or `re-plan`, or with no clear recommendation.
- **Fix loops:** verifier→implementer and quick-fix→delta-review loops stop after `MAX_AUTO_FIX_ROUNDS` (default 2).
- **Before shipping:** one stop. The user reviews `evidence.md`, `mr.md` and the auto-decisions summary, runs `approve-evidence.sh`, and confirms the push. The chat go-ahead that came before the push goes away.
- **MR open:** the run ends there. `/fetch-review` resumes it after Duo has reviewed. From there it stops only for ASK threads and the push confirmation.
- **Answering a stop:** only an explicit approval moves the run on. Any other reply is folded in as feedback, and the same stop repeats.

## How it works

- **Starting a run:** the user picks `pipeline` once and runs `/start-task <id> <slug>`. Every stop is answered in that same chat.
- **Subagents return, they don't ask:** a subagent never asks the user anything. It returns to the orchestrator, and only the orchestrator shows the user a `⏸ DECISION NEEDED` block.
- **How a stage knows it's in a run:** the orchestrator's prompt to each subagent starts with `AUTO RUN`. The signal lives only in the prompt, so manual stage-by-stage use is unchanged and no state file can leave a run stuck in "auto".
- **Files the orchestrator keeps:** `.work/<id>/status.md` (current stage, fix round, pending stop) and `.work/<id>/auto-decisions.md` (each automatic decision, why it was made, and which rule allowed it).
- **Orchestrator model:** pinned to the cheapest model (GPT-6 Luna). If subagents turn out to be limited to their parent's cost tier, it moves to Claude Opus 5.5.
- **Manual mode stays:** the stage agents and their `handoffs:` remain usable on their own until the Local harness is removed.

## Considered options

- **Handoffs with `send: true`:** handoffs are "Copilot: Not supported", and the Local harness is deprecated.
- **One agent that runs every stage itself:** this loses the per-stage pinned models, which the pipeline relies on for cost and for an independent verifier and reviewer. It also loses the fresh context per stage, so token use would grow across the whole task.
- **Routing on each agent's `**Next:**` line:** the model's free text would decide what runs next. Stop rules written as instructions to a model can't be tested.

## Consequences

- **The Auto model picker cancels pinned models.** When the session model is Auto, subagents inherit it and ignore their `model:` line. The docs and the orchestrator warn against using Auto.
- **The design rests on four behaviours not confirmed for VS Code Agent Host.** A throwaway spike must confirm them before anything is built:
  1. The `preToolUse` guard's **deny** fires inside a subagent. **If it doesn't, this design is abandoned.**
  2. A guard **ask** inside a subagent shows the user a confirm prompt. If not, every publishing script (`create-mr.sh`, `push-branch.sh`, `upload-evidence.sh`, ClickUp writes) runs in the orchestrator at the top level instead.
  3. A subagent runs on its own pinned `model:`, and isn't limited by its parent's cost tier.
  4. `copilot-instructions.md` reaches subagents. The CLI docs say it doesn't unless `include-custom-instructions: true` is set.
- **Also checked in the spike:**
  - whether the hook input identifies the top-level agent. If it doesn't, the "orchestrator edits only `.work/`" rule rests on instructions, and the guard's deny rules still apply to every agent.
  - whether `chat.notifyWindowOnConfirmation` and the `chatUserActionRequired` sound fire in Agent Host sessions.

## Sources (checked 2026-11-18)

- **Agent harnesses:** https://code.visualstudio.com/docs/agents/concepts/agent-harnesses (Local harness removal)
- **Custom agent file reference:** https://code.visualstudio.com/docs/agents/reference/custom-agent-file-reference (handoffs and `agents:` not supported in Copilot)
- **Subagents:** https://code.visualstudio.com/docs/agents/run/subagents (fresh context, model resolution, no ask tools in Local subagents)
- **Copilot CLI reference:** https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-command-reference (subagent model inheritance under Auto, `include-custom-instructions`, `modelPolicy`)
- **Hooks reference:** https://docs.github.com/en/copilot/reference/hooks-reference (hooks inside subagents carry `agentId`/`parentAgentId`)
- **VS Code hooks:** https://code.visualstudio.com/docs/agent-customization/hooks (`ask` needs an interactive flow)
- **Agent Host lists custom agents in `task`:** https://github.com/microsoft/vscode/pull/340866
- **Duplicate custom agents in Agent Host's `task`:** https://github.com/microsoft/vscode/issues/345479
