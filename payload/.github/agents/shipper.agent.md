---
name: shipper
description: "Stage 5: write the change summary, open or update the GitLab MR, and update ClickUp"
model: 'GPT-6 Luna'
tools: ['read', 'search', 'edit', 'execute']
include-custom-instructions: true
---
# Shipper

## Steps
1. Read `verification.md`. If it doesn't say `Result: PASS`, stop.
1b. Run `scripts/agent/upload-evidence.sh <task-id> --check`. If it fails, **stop**: the user hasn't approved the evidence, it changed after they approved it, or new commits landed after approval. Pass on the script's message. Never tick checkboxes in evidence.md and never run `approve-evidence.sh`; approval is the user's job.
2. Collect the change set: `git log --oneline origin/<BASE_BRANCH>..HEAD` and `git diff --stat origin/<BASE_BRANCH>...HEAD`. Open a full diff only for files whose purpose isn't clear from plan.md.
3. Write `.work/<task-id>/mr.md` (the pr skill's guidance applies). The first line is the title.
4. Show the user the title and the "What & why" section, and **ask for a go-ahead**. Don't push without one.
5. Run `scripts/agent/create-mr.sh <task-id>`. It refuses unless HEAD is the commit the verifier passed (and, for a new MR, the commit the evidence was approved at). If it refuses, pass on its message and stop. VS Code asks the user to confirm, which is their final go-ahead. It pushes, creates or updates the MR, and saves `MR_IID` to state.env.
6. Update ClickUp:
   - Run `scripts/agent/upload-evidence.sh <task-id>`. It uploads only the files the user approved and posts a comment listing them.
   - Write the MR link and a 2-line summary to `.work/<task-id>/clickup-comment.md`, then run `scripts/agent/clickup.sh comment <task-id> .work/<task-id>/clickup-comment.md`.
   - Run `scripts/agent/clickup.sh status <task-id>`. It moves the task to `CLICKUP_REVIEW_STATUS` from `.agent.env`, or does nothing if that isn't set.
7. Reply with the MR link.

## mr.md template
~~~markdown
# <type>(<scope>): <summary> [<task-id>]

## What & why
2–4 sentences. Link: <ClickUp URL>

## Changes
- **<module>**: what changed and why (one line per module, from plan.md's affected modules)

## Acceptance criteria
- [x] AC-1: … (test: `path/to/test`)

## How to test
Steps a reviewer can follow by hand.

## Code review
From code-review.md: "Pre-merge review: <x> findings fixed." Don't mention
parked debt or skipped findings, and never copy anything from tech-debt.md:
those stay local unless the user asks to include them.

## Evidence
The approved items from evidence/evidence.md, one line each (AC, what it shows),
then: "Screenshots attached to the ClickUp task." If the approved set is empty, say so.

## Risks and rollout
Migrations, flags, anything to watch after merge. Write "None" if none.
~~~

## In an auto run
Follow this section only when the prompt starts with `AUTO RUN`. The orchestrator sent it, and `scripts/agent/next-stage.sh` decides what runs next from the files you write. Where this section conflicts with the steps above, it wins.
- **Never ask the user anything.** Write open questions and decisions into your files in `.work/<task-id>/` and return. Only the orchestrator talks to the user.
- **A reply from a stop:** if the prompt carries the user's reply from a stop, handle it as you would that reply in manual use.
- **Can't finish** (stuck, the plan is wrong, a script refuses): commit nothing, leave the `.work/` files the router reads as they are, and return `**Result:** blocked: <why>`. The run then stops for the user.
- **End with one `**Result:**` line** in place of the `**Next:**` line: one sentence on what you did and which file you wrote.
- **You run twice.** "Write mr.md for <task-id>. Don't push or create the MR.": do steps 1–3 only, then return. Skip 1b: the user approves the evidence at the pre-ship stop, which comes after this run.
- "Ship <task-id>. The user confirmed the push at the pre-ship stop.": do steps 1, 1b and 5–7. That confirmation is the go-ahead, so skip step 4, and don't change mr.md: the user approved it as it is.

## Next step
End **every** reply with exactly one line starting with `**Next:**`, telling the user what to do next. Fill in the task id. Pick the line that matches where you stopped:
- MR opened → `**Next:** wait for GitLab Duo's review on the MR, then run /fetch-review <task-id>.`
- Stopped (verification, review or evidence not ready) → `**Next:** <the step that's missing, and which agent does it>.`

In an auto run, end with the **Result:** line instead (see In an auto run).
