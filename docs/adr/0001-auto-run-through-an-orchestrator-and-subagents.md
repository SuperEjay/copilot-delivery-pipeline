---
status: accepted (2026-11-18, after the subagent spike in issue #2; the pinned-model check is still unverified, see Consequences)
---

# Auto run through an orchestrator and subagents

We want a task to move through the pipeline without the user picking the next agent and typing a phrase at every stage. The pipeline should **stop** only where a human decision is needed. A new `pipeline` agent (the **orchestrator**) runs each of the eight stage agents as a Copilot subagent. A deterministic script, `scripts/agent/next-stage.sh`, decides which stage runs next or whether to stop, from the files already in `.work/<task-id>/`. We do it this way for three reasons. Handoffs don't work in Copilot (Agent Host) sessions, and the Local harness that supports them is being removed in February 2027. Subagents keep each stage's pinned model and a fresh context window. And a script makes the stop rules testable instead of leaving them to a model's judgment.

## Stop rules

- **Requirements:** always stops. Misreading the ticket is the costliest mistake.
- **Plan:** stops only on requirement gaps, a migration, a feature flag, work for another team, or more than 6 slices.
- **Code review:** reviewer recommendations are accepted automatically and recorded as **auto-decisions**. It stops only for findings routed to `requirements` or `re-plan`, or with no clear recommendation.
- **Fix loops:** verifier→implementer and quick-fix→delta-review loops stop after `MAX_AUTO_FIX_ROUNDS` (default 2).
- **Before shipping:** one stop. The user reviews `evidence.md`, `mr.md` and the auto-decisions summary, runs `approve-evidence.sh`, and confirms the push. The chat go-ahead that came before the push goes away. The orchestrator raises this push confirmation as its own stop: it doesn't rely on the guard's ask prompt, because VS Code can remember an approval for the rest of the session, so a later push would go through without a prompt.
- **MR open:** the run ends there. `/fetch-review` resumes it after Duo has reviewed. From there it stops only for ASK threads and the push confirmation.
- **Answering a stop:** only an explicit approval moves the run on. Any other reply is folded in as feedback, and the same stop repeats.

## How it works

- **Starting a run:** the user picks `pipeline` once and runs `/start-task <id> <slug>`. Every stop is answered in that same chat.
- **Subagents return, they don't ask:** a subagent never asks the user anything. It returns to the orchestrator, and only the orchestrator shows the user a `⏸ DECISION NEEDED` block.
- **How a stage knows it's in a run:** the orchestrator's prompt to each subagent starts with `AUTO RUN`. The signal lives only in the prompt, so manual stage-by-stage use is unchanged and no state file can leave a run stuck in "auto".
- **Files the orchestrator keeps:** `.work/<id>/status.md` (current stage, fix round, pending stop) and `.work/<id>/auto-decisions.md` (each automatic decision, why it was made, and which rule allowed it).
- **Orchestrator model:** pinned to the cheapest model (GPT-6 Luna).
- **Stage models:** the orchestrator names each stage's model on every subagent call, as well as the stage agent's own `model:` line. A `model:` line the session can't use falls back to the session's model without any error; a model named on the call is applied as an explicit override.
- **Pipeline rules in subagents:** every stage agent sets `include-custom-instructions: true`, so `copilot-instructions.md` reaches it when it runs as a subagent.
- **Orchestrator edits only `.work/`:** this rests on the orchestrator's instructions. The guard can tell a subagent's tool call from a top-level one, but not which agent is at the top level, so it can't tell the orchestrator from a stage agent the user runs by hand. The guard's deny rules apply to every agent either way.
- **Manual mode stays:** the stage agents and their `handoffs:` remain usable on their own until the Local harness is removed.

## Considered options

- **Handoffs with `send: true`:** handoffs are "Copilot: Not supported", and the Local harness is deprecated.
- **One agent that runs every stage itself:** this loses the per-stage pinned models, which the pipeline relies on for cost and for an independent verifier and reviewer. It also loses the fresh context per stage, so token use would grow across the whole task.
- **Routing on each agent's `**Next:**` line:** the model's free text would decide what runs next. Stop rules written as instructions to a model can't be tested.

## Consequences

- **The Auto model picker cancels pinned models.** When the session model is Auto, subagents inherit it and ignore their `model:` line. The docs and the orchestrator warn against using Auto.
- **Spike results** (issue #2, VS Code 1.146.0 Agent Host under WSL, on Copilot Free, so the session ran on Auto). Each result is taken from the session transcript and the hook log:
  1. **The guard's deny fires inside a subagent.** A subagent's `git push` returned `Denied by preToolUse hook: …`. This was the make-or-break check.
  2. **A guard ask inside a subagent shows the user a confirm prompt**, so publishing scripts can stay in the shipper and review-responder. The approval can be remembered for the rest of the session, which is why the push confirmation is a stop (see Stop rules).
  3. **Pinned models: unverified.** Copilot Free offers only Auto, and a `model:` line the plan can't use was ignored without any error. A model named on the subagent call was applied. This needs re-checking on a paid plan.
  4. **`copilot-instructions.md` reached a subagent only with `include-custom-instructions: true`.** The two subagents compared ran on different models, so this result is indicative, not clean.
  5. **The hook input names subagents, not the top-level agent.** A subagent's call carries `agentId`, `agentType` and `parentAgentId`; a top-level call carries none of them.
  6. **Alerts: unverified.**
- **Agent Host lists every custom agent twice in `task`:** once by name and once as `vscode-agent-<hash>` (microsoft/vscode#345479). The orchestrator calls stages by name.

## Sources (checked 2026-11-18)

- **Agent harnesses:** https://code.visualstudio.com/docs/agents/concepts/agent-harnesses (Local harness removal)
- **Custom agent file reference:** https://code.visualstudio.com/docs/agents/reference/custom-agent-file-reference (handoffs and `agents:` not supported in Copilot)
- **Subagents:** https://code.visualstudio.com/docs/agents/run/subagents (fresh context, model resolution, no ask tools in Local subagents)
- **Copilot CLI reference:** https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-command-reference (subagent model inheritance under Auto, `include-custom-instructions`, `modelPolicy`)
- **Hooks reference:** https://docs.github.com/en/copilot/reference/hooks-reference (hooks inside subagents carry `agentId`/`parentAgentId`)
- **VS Code hooks:** https://code.visualstudio.com/docs/agent-customization/hooks (`ask` needs an interactive flow)
- **Agent Host lists custom agents in `task`:** https://github.com/microsoft/vscode/pull/340866
- **Duplicate custom agents in Agent Host's `task`:** https://github.com/microsoft/vscode/issues/345479
