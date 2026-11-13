# Delivery pipeline (applies to every agent)

- One ClickUp task = one folder, `.work/<task-id>/`. `state.env` holds TASK, BRANCH and MR_IID.
- Files are the handoff: requirements.md → plan.md → verification.md → code-review.md → evidence/evidence.md → mr.md → review.json. Read the file; don't ask the user to repeat what's in it.
- Evidence approval belongs to the user alone. Never tick evidence checkboxes, and never run `approve-evidence.sh` or edit `evidence/APPROVED`.
- Run tests, lint and typechecks only through `scripts/agent/run-checks.sh <task-id> <checks>`, never as raw commands. Full logs are in `.work/<task-id>/logs/`; search them, don't read them whole.
- Refer to acceptance criteria by id (AC-n) in plans, tests, commits and the MR.
- Keep replies to the user short. Lead with what needs their decision. Don't restate file contents.
- Never push, open an MR, or change a ClickUp status without the user's go-ahead in the current session.
- Each agent runs on the model pinned in its file. Never switch to a fast, priority or other premium-speed variant of any model: they cost several times more for the same work.
