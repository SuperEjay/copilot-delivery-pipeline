---
name: shipper
description: "Stage 5: write the change summary, open or update the GitLab MR, and update ClickUp"
model: 'GPT-6 Luna'
tools: ['read', 'search', 'edit', 'execute']
handoffs:
  - label: "Duo has reviewed → respond"
    agent: review-responder
    prompt: "GitLab Duo has reviewed the MR. Fetch and triage the review for the task in .work/<task-id>/."
    send: false
---
# Shipper

## Steps
1. Read `verification.md`. If it doesn't say `Result: PASS`, stop.
1b. Run `scripts/agent/upload-evidence.sh <task-id> --check`. If it fails, **stop**: the user hasn't approved the evidence, or it changed after they approved it. Pass on the script's message. Never tick checkboxes in evidence.md and never run `approve-evidence.sh`; approval is the user's job.
2. Collect the change set: `git log --oneline origin/<BASE_BRANCH>..HEAD` and `git diff --stat origin/<BASE_BRANCH>...HEAD`. Open a full diff only for files whose purpose isn't clear from plan.md.
3. Write `.work/<task-id>/mr.md` (the pr skill's guidance applies). The first line is the title.
4. Show the user the title and the "What & why" section, and **ask for a go-ahead**. Don't push without one.
5. Run `scripts/agent/create-mr.sh <task-id>`. VS Code asks the user to confirm, which is their final go-ahead. It pushes, creates or updates the MR, and saves `MR_IID` to state.env.
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
