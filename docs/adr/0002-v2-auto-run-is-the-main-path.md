---
status: accepted (2026-11-19, after the v2 scope grilling; the release waits on the pinned-model check, see Consequences)
---

# v2: auto run is the main path

VS Code removes the Local harness in February 2027, and with it the `handoffs:` buttons the stage agents still carry. ADR 0001 already moved the pipeline onto an **auto run**: the `pipeline` agent (the **orchestrator**) runs each stage as a subagent, and `next-stage.sh` (the **router**) decides what comes next. v2.0.0 makes that the main path and removes what only existed for the old way of working, and for upgrades from before auto run. We aim to release it in January 2027, before the removal. v1.2.x keeps working after February 2027: its handoff buttons just stop showing.

## Decisions

- **Auto run is the main path.** The README and `docs/agent-pipeline.md` lead with the `pipeline` agent and `/start-task`.
- **Manual mode stays, as the fallback.** Each stage agent can still be picked by hand, and still ends a manual reply with a `**Next:**` line. It is cheap to keep, and it is the way through when a VS Code update breaks subagents or pinned models.
- **`handoffs:` is removed** from all eight stage agents. In Copilot (Agent Host) sessions they never worked, and after February 2027 nothing shows them.
- **The `load_state` and `set_state` shims are removed** from `task-state.sh`. v1.2.0 deprecated them in favour of the `state_*` readers and writers.
- **`--update` accepts v1.2.x and later only.** It reads the installed version from the first line of `.github/agent-pipeline.manifest` (written by every installer since v1.0.0) and refuses anything older, telling the user to update to v1.2.2 first. `--force` does not override this. A fresh install is not affected. This drops the v1.1.0 upgrade path: the router's check for a `plan.md` without `## Stop flags` and the v1.1.0 case in `tests/test-install.sh`.
- **A task started on v1.2.x carries on under v2.** The formats of `status.md`, `state.env` and the other `.work/<id>/` files don't change, so nobody has to finish their open tasks before updating.
- **A run log.** `next-stage.sh` appends one line to `.work/<id>/run.log` for each decision (`run`, `stop`, `end`) and each approval: time, the decision, the agent or stop id, the fix round and HEAD. It is the only writer. The guard protects the file like `status.md`: agents may read it but not change it. Copilot gives scripts no per-stage token or model data, so neither is logged. A missing `run.log` reads as empty.
- **`scripts/agent/doctor.sh`.** An installed script that checks a setup and changes nothing: the required tools, `glab` login, `CLICKUP_API_TOKEN` exported and not in a file, settings missing from `.agent.env`, `.sh` files with CRLF line endings, the guard blocking a test `git push`, and the VS Code version. It prints PASS, WARN or FAIL per check and exits non-zero on a FAIL. The installer runs it at the end, in place of its own guard check. It can't start a subagent, so for pinned models it only prints how to check by hand.
- **WSL is the only supported way to run on Windows.** Git Bash stays in the README, marked unsupported. Nobody has tested it, and the guard may not run there; `doctor.sh` fails when it doesn't.
- **Alerts stay optional and unverified.** Nothing depends on them.

## Seams named, not built

The pipeline talks to three outside systems: a **tracker** (ClickUp: fetch the task, move its status, attach evidence), a **forge** (GitLab through `glab`: push, open the MR, read and answer review threads) and a **review bot** (GitLab Duo: which authors' threads the review-responder answers). v2 names these as the places another provider would plug in, but builds no second provider and renames nothing: `clickup.sh`, `fetch-duo-review.sh` and `DUO_USERNAMES` keep their names. Renaming them now would break every user's `.agent.env` and scripts for no benefit today. The renames come with the first real second provider, even if that means a v3.

## Release

- Changes merge straight into `main`. The README keeps pinning v1.2.2 until v2.0.0 is out, so nobody gets unreleased work by following it. If v1.2.x needs a fix, `release/v1.2.x` is cut from the tag then.
- `v2.0.0-rc.1` is tagged as a GitHub pre-release once the changes are in.
- **The pinned-model check blocks the release.** A teammate on a paid Copilot plan installs the release candidate, runs a real task, and confirms that each stage runs on its pinned model. The result goes into ADR 0001's Consequences. The author is on Copilot Free, which only offers Auto, so this can't be checked there.
- The CHANGELOG gets an "Upgrading to v2" section: update to v1.2.2 first, merge any `<file>.new` agent files (their handoffs are gone), check that no script you changed still calls `load_state` or `set_state`, and on Windows move to WSL.

## Considered options

- **Drop manual mode:** less to document, but it leaves no way through when auto run breaks, and VS Code has already shipped Agent Host bugs that hit it (microsoft/vscode#345479).
- **Build tracker and forge adapters in v2:** this widens the audience, but no user needs another provider yet, and it would put a much larger change on the February 2027 deadline.
- **Keep the v1.1.0 upgrade path:** one extra update to v1.2.2 is a small cost for whoever is still on v1.1.0, and it removes code that only exists for upgrades.
- **Rewrite `next-stage.sh` in Node:** it is tested and runs on macOS's bash 3.2. A rewrite costs a lot for little gain.
- **Headless runs through Copilot CLI:** the guard's ask prompts need an interactive session, so this changes the trust model and needs its own ADR.

## Consequences

- **A breaking release.** Anyone on v1.1.0 or older updates twice, and a script a user changed that still calls `load_state` or `set_state` stops working.
- **v2.0.0 isn't released until the pinned-model check passes on a paid plan.** If pinned models turn out not to work in subagents, the per-stage model design in ADR 0001 has to be revisited before the release.
- **Windows users on Git Bash lose support** and should move to WSL.
- **Stage agents ship without handoffs before the Local harness is gone.** A user still on the Local harness between v2.0.0 and February 2027 picks the next stage from its `**Next:**` line, as Agent Host users already do.
