---
status: accepted (2026-11-25, after the /start-task auto-continue grilling; #130). Amends ADR 0001's requirements stop rule.
---

# The requirements stop waits for the plan when nothing is open

ADR 0001 made the requirements stop unconditional: "Misreading the ticket is the costliest mistake." In practice every auto run paused straight after the requirements agent, even when `requirements.md` had no open questions, so "start a task" never got as far as a plan without another reply. Simply dropping the stop isn't safe: the plan stops only on a stop flag or more than `MAX_PLAN_SLICES` slices, so a clean run could reach `pre-ship` before anyone read the requirements.

## Decisions

- **Open questions decide where the run first stops.** With at least one list item under `## Open questions` in `requirements.md`, the `requirements` stop comes first, as before. With none, the router runs the planner without a requirements approval.
- **One combined stop instead.** While the requirements are unapproved, the `plan` stop always fires, stop flags or not. Its reason names `requirements.md` and `plan.md`, its approval is tied to a checksum of both, and approving it records both approvals.
- **A missing `## Open questions` section is unreadable**, a stop no approval passes, like a missing `## Stop flags` line. An empty section has to be written on purpose.
- **Assumptions don't stop the run early.** They're confirmed at the combined stop, next to the plan that rests on them.
- **The same rule every time the requirements change** mid-run: open questions bring the `requirements` stop; otherwise the planner updates the plan and the combined stop comes back.
- **Feedback at the combined stop** goes to the requirements agent when it's about the acceptance criteria, scope or assumptions (the planner then re-plans), and to the planner otherwise.
- **No setting** to bring back the old always-stop behaviour.

## Considered options

- **Keep the requirements stop always:** safe, but the extra reply carries no decision when nothing is open, and it's what made `/start-task` feel like it stopped halfway.
- **Pass the requirements stop automatically when nothing is open:** fewest replies, but a run with an unflagged plan would show the user nothing before `pre-ship`. The human check on the ticket reading would be gone.

## Consequences

- **The user still reviews the requirements on every run**, just together with the plan, so a misread ticket is caught before any code is written.
- **A misread ticket can cost one planner run.** Feedback about the requirements at the combined stop means the requirements and the plan are both redone.
- **The requirements agent must always write the section.** In an auto run, it leaves `## Open questions` with no list items when there are none. Manual mode is unchanged.
- **MR reviews are unaffected.** They have no requirements stop. Their `spec` stop is separate (ADR 0003).
