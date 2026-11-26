# Changelog

## Unreleased

- **Fixed:** in default Agent mode (or any agent other than the stage agent the skill names), `/start-task`, `/fetch-review` and `/review-mr` ended with "pick the **pipeline** agent", and saying `Run <task-id>` there could make that agent start **pipeline** as a subagent. As a subagent, the guard refused it `next-stage.sh` and it hit the subagent depth limit, so the run did nothing. `pipeline.agent.md` now sets `disable-model-invocation: true`, so no agent can start it as a subagent. The hand-off now says to switch the agent picker to **pipeline**, and tells the agent never to start it itself. Upgrading: merge `pipeline.agent.md.new` and the three skills' `SKILL.md.new`.
- **Fixed:** in an auto run, the planner wrote a plan but couldn't save `plan.md`, so you had to run the planner again yourself. As a subagent it got no file-editing tool, and unlike every other stage agent it had no shell. The planner now has `execute`, and every stage agent is told to write its files through the shell when it has no file-editing tool. Upgrading: merge the eight stage agents' `.agent.md.new`.

## v2.5.0

**Finished tasks clean up, and fewer stops.** `/cleanup` removes a task's branch, work folder or review worktree once its MR is merged or closed, and doctor lists each finished task with the command to run. An auto run whose requirements have no open questions goes on to the planner and stops once, at the plan, for both. The skills hand you to the **pipeline** agent instead of into manual mode, and doctor shows the test commands and tools for a Node or Laravel project.

**Not yet tried for real:**
- `/cleanup` and `/cleanup --finished` against a real GitLab: only checked with the tests' fake glab.
- The combined requirements-and-plan stop (ADR 0006) in a real auto run: checked through the router tests and the agent files.
- From v2.4.0, still: a full auto run in a project without Playwright, and the gap-checker agent in VS Code.

### Upgrading to v2.5.0

1. From v2.4.0 (or earlier, see the earlier upgrade notes first), run `install.sh --update` from v2.5.0: `curl -fsSL https://raw.githubusercontent.com/SuperEjay/copilot-delivery-pipeline/v2.5.0/install.sh | bash -s -- --update`.
2. Merge each `<file>.new` it reports. `pipeline.agent.md` and `requirements.agent.md` changed (the combined plan stop), and so did the `start-task`, `fetch-review` and `review-mr` skills. The `cleanup` skill is new.
3. No new `.agent.env` settings. Doctor's new "test tooling" section only suggests lines to paste.
4. Commit the updated pipeline files (with `--local`, there's nothing to commit), fully quit and reopen VS Code. `/cleanup` should now be offered in the chat.
5. **Changed:** `/review-mr <iid> --done` now needs the MR merged or closed (or `/cleanup mr-<iid> --force`), and it deletes `.work/mr-<iid>/` too.

Tasks in progress carry on. A task waiting at a `requirements` stop with no open questions now goes on to the planner on its next run.

### Changes

- **Test tooling per stack** (#131). `doctor.sh`, and so the end of every install and `--update`, prints a "test tooling" section: ready-to-paste `.agent.env` lines for each check of a Node or Laravel project, and the tool to install where one is missing (Laravel: Pest, else PHPUnit, Pint, Larastan, and the Pest browser plugin for e2e with Playwright as the alternative). It only recommends: nothing is written to `.agent.env` or installed. A command `.agent.env` sets to other than the example's value wins. The stacks are one table in `scripts/agent/stacks.sh`; another stack gets a one-line "set the commands by hand".
- **`/cleanup` removes what a finished task leaves behind** (#132). Once a task's MR is merged or closed, `/cleanup <id>` (new skill, new `scripts/agent/cleanup-task.sh`) deletes its `.work/<id>/` folder and, when merged, its local branch (even after a squash merge); a closed MR's branch is kept, with the `git branch -D` command printed. The remote is never touched. It refuses while the MR is open, without an MR (`--force` for a task you abandoned), when glab can't tell the MR's state, on the task's branch, with uncommitted changes, or while `tech-debt.md` has parked debt (listed; `--drop-debt` goes ahead). `/cleanup --finished` sweeps every finished task and prints a summary. `doctor.sh` now lists every finished task (not only review worktrees) with its `/cleanup` command, `/fetch-review` on a merged or closed MR points to `/cleanup`, and the guard asks before an agent runs a cleanup.
  - **Changed:** `/review-mr <iid> --done` is now the same cleanup: it needs the MR merged or closed (or `/cleanup mr-<iid> --force`), and it deletes `.work/mr-<iid>/` too instead of keeping it.
- **`cleanup-task.sh --finished --list`** (#140). It prints `<task> <iid> <state>` for each task with an MR and changes nothing; `unknown` when glab can't read the MR. `doctor.sh` now gets its list of finished tasks from it instead of reading `.work/` itself, so what counts as a task and its MR lives in one place. Doctor's output is unchanged; when glab isn't logged in, the list still asks GitLab and doctor ignores the answers.
- **Internal: `forge_mr_state`** (#139). `forge-lib.sh` gives an MR's state on its own, and fails with nothing on stdout when glab or jq is missing or glab fails. `doctor.sh`, `cleanup-task.sh` and `fetch-duo-review.sh` use it instead of reading the state field from `forge_mr`'s line themselves. No change in behaviour.
- **No open questions, no early stop** (#130, ADR 0006). When requirements.md has no list items under `## Open questions`, an auto run no longer stops after the requirements agent: it goes on to the planner, and the `plan` stop then shows requirements.md and plan.md together. Approving it approves both. With a question open, the `requirements` stop comes first as before. A requirements.md without the `## Open questions` section is a stop no approval passes. Feedback at the `plan` stop about the acceptance criteria, scope or assumptions goes to the requirements agent; anything else to the planner. `next-stage.sh`, `pipeline.agent.md` and `requirements.agent.md` changed.
- **`/start-task` and `/fetch-review` point to the pipeline agent** (#129). Run in any agent other than **pipeline** or the stage agent that goes on by itself (**requirements**, **review-responder**), they still set up the task or fetch the review, then say "pick the **pipeline** agent and say `Run <task-id>`" (or `Continue <task-id>`) instead of sending you into manual mode. Manual mode now starts by picking the stage agent first; the guide's table says so. `start-task/SKILL.md` and `fetch-review/SKILL.md` changed.

- **Pinned models are confirmed on a paid plan** (#67). On a paid Copilot plan, with a model other than Auto picked, each stage of a real auto run ran on its pinned model. The guide's "Pinned models in an auto run", ADR 0001 and ADR 0002 now say so. Docs only.

## v2.4.0

**UI work without Playwright, start to finish.** In a project without Playwright, a UI acceptance criterion whose logic is unit- or integration-tested now passes with a recorded gap instead of failing, evidence falls back to text (plus any screenshots you save yourself), and the pre-ship stop says how many gaps there are. Before approving, you can have the new **gap-checker** agent walk those criteria in VS Code's built-in browser. The #113 spike settled why that's a separate agent you pick yourself: VS Code doesn't give subagents the browser tools, so nothing in the auto run can drive a browser (ADR 0005).

**Not yet tried for real:**
- A full auto run in a project without Playwright: the `PASS (gap)` grading, Text evidence and the gap count at the pre-ship stop have only been checked through the agent files and the router tests.
- The gap-checker agent in VS Code. The spike proved the browser tools themselves, not this agent's instructions.
- Pinned models are still unverified on a paid plan (#67). gap-checker is pinned to Claude Sonnet 5.5; on Copilot Free it runs on Auto.

### Upgrading to v2.4.0

1. From v2.3.0 (or earlier, see the earlier upgrade notes first), run `install.sh --update` from v2.4.0: `curl -fsSL https://raw.githubusercontent.com/SuperEjay/copilot-delivery-pipeline/v2.4.0/install.sh | bash -s -- --update`.
2. Merge each `<file>.new` it reports. `verifier.agent.md` and `evidence.agent.md` changed (grading and evidence without Playwright). `gap-checker.agent.md` is new.
3. No new `.agent.env` settings. gap-checker opens `EVIDENCE_BASE_URL`, so set it if your app isn't on `http://localhost:3000`.
4. Commit the updated pipeline files (with `--local`, there's nothing to commit), fully quit and reopen VS Code. **gap-checker** should now be in the agent picker.

Tasks in progress carry on.

### Changes

- **UI acceptance criteria and evidence work without Playwright** (#114, ADR 0005). With e2e skipped, the verifier grades a UI AC whose logic is covered by unit or integration tests `PASS (gap)` instead of FAIL, and lists it under Gaps; an AC no test covers at all still fails. The pre-ship stop says how many gaps `verification.md` lists. `capture-evidence.sh` exits 3 without Playwright, and the evidence agent writes Text evidence for screenshot ACs; PNGs you save in `evidence/` yourself are listed and approved like any other file. The #113 spike found VS Code's browser tools aren't available to subagents, so there are no live browser checks.
- **Check the gaps in VS Code's browser** (#123). A new **gap-checker** agent, which you pick yourself at the pre-ship stop, walks each `PASS (gap)` AC in VS Code's built-in browser (no Playwright) and writes `.work/<id>/gap-checks.md`: `looks right`, `looks wrong` or `couldn't check`, with what it saw. It changes nothing else and never counts toward `VERIFIED` (ADR 0005). When there are gaps and no Playwright, the pre-ship stop points to it. It can't run inside the auto run, because VS Code doesn't give subagents the browser tools (#113).

## v2.3.0

**No Playwright, no blocker.** A project without Playwright now gets through the full delivery pipeline: e2e is skipped and recorded as a gap instead of failing the verifier and blocking the push (ADR 0005). Local installs also keep every agent skill out of git, not just the two the installer adds.

**Not yet tried for real:**
- A full auto run in a project without Playwright. The verifier's Gaps line and the reviewer's view of it have only been checked through the agent files, not with a real model.
- The evidence stage still needs Playwright for screenshots. Without it, screenshot ACs can't be captured yet (#114, after the #113 spike).

### Upgrading to v2.3.0

1. From v2.2.0 (or earlier, see the earlier upgrade notes first), run `install.sh --update` from v2.3.0: `curl -fsSL https://raw.githubusercontent.com/SuperEjay/copilot-delivery-pipeline/v2.3.0/install.sh | bash -s -- --update`.
2. Merge each `<file>.new` it reports. `verifier.agent.md` changed (skipped checks go under Gaps).
3. **If your project has no Playwright, remove the `E2E_CMD="npx playwright test …"` line from `.agent.env`.** An explicit `E2E_CMD` still wins, so that line keeps e2e failing. `scripts/agent/doctor.sh` warns about it.
4. With `--local`, the update replaces the ponytail/caveman lines in `.git/info/exclude` with `/.agents/`. Skills you'd committed under `.agents/` stay tracked; the installer prints how to untrack them.
5. Commit the updated pipeline files (with `--local`, there's nothing to commit), fully quit and reopen VS Code.

Tasks in progress carry on.

### Changes

- **e2e is skipped, not failed, when the project has no Playwright** (#112, ADR 0005). `E2E_CMD` now defaults to Playwright only when `package.json` has `@playwright/test`; otherwise `run-checks.sh` prints `SKIP  e2e`, `all` can still print `VERIFIED`, and the verifier lists the skip under Gaps. An explicit `E2E_CMD` (even empty) still wins. `.agent.env.example` no longer sets `E2E_CMD`. `doctor.sh` reports when e2e will be skipped, and warns when `E2E_CMD` runs Playwright in a project without it: remove that line from your `.agent.env` to get the new default.
- **`--local` keeps the whole `.agents/` folder out of git** (#115). It used to ignore only the ponytail and caveman skills, so any other skill added with `npx skills add` showed up as untracked. `--update` replaces the old lines. If skills under `.agents/` are already committed, the installer says they stay tracked and how to untrack them. Shared installs are unchanged.

## v2.2.0

**Adopt your own work, and fewer Duo round-trips.** `/start-task <clickup-id> --mr <iid>` or `--branch <branch>` puts work you began outside the pipeline through the whole delivery route (ADR 0004). A Duo `suggestion` block is applied by a script instead of being rewritten. Threads you already answered aren't triaged again, and the pipeline's replies are tagged `**[pipeline]**`. Under the hood, one module now owns GitLab (`forge-lib.sh`) and one owns a Duo round's formats (`duo-round-lib.sh`). The review-responder writes `review-triage.md` from a template, and the router reads it strictly.

**Not yet tried for real:**
- Everything that talks to GitLab has run only against a fake `glab`: `/start-task --mr`, `create-mr.sh`, replies and resolves, `/review-mr`'s posted threads, and `/fetch-review`.
- A Duo round in an auto run with a real model. Check that the review-responder's `review-triage.md` follows the template: a verdict like `**FIX**` or `Fix` stops the run until the file is fixed.
- `apply-suggestion.sh` on macOS's own bash 3.2 (only checked statically).
- Pinned models are still unverified on a paid plan (#67).

### Upgrading to v2.2.0

1. From v2.1.0 (or v2.0.0, or any v1.2.x, see "Upgrading to v2" first), run `install.sh --update` from v2.2.0: `curl -fsSL https://raw.githubusercontent.com/SuperEjay/copilot-delivery-pipeline/v2.2.0/install.sh | bash -s -- --update`.
2. Merge each `<file>.new` it reports. **`review-responder.agent.md` matters most:** its new `review-triage.md template` is what the router now reads, and without it a Duo round stops as unreadable. The planner, shipper and reviewer agents and the `start-task` skill changed too (adopting a branch or MR).
3. No new `.agent.env` settings.
4. Commit the updated pipeline files (with `--local`, there's nothing to commit), fully quit and reopen VS Code.

Tasks in progress carry on. A task in the middle of a Duo round keeps its round as long as its open Duo threads are the same ones as at its last fetch. Its next round records `REVIEW_SEEN` in place of `REVIEW_IDS`.

### Changes

- **Suggestions are applied, not rewritten** (#95). When a review thread the review-responder triages FIX carries a GitLab ```` ```suggestion ```` block, it runs the new `scripts/agent/apply-suggestion.sh <task-id> <thread-id>` instead of writing its own fix. It saves tokens and lands exactly what the reviewer asked for. The script puts the lines in place in the working tree and commits nothing; the checks, the verifier and the push gate run as before. It applies the block where the reviewer's lines still are, at the same line numbers or, if they moved, where they appear exactly once. It refuses (exit 3, nothing written) when they changed, when the comment offers several blocks (alternatives), or when the thread is on a removed line. Then the fix is made by hand. Threads applied as they are get the reply "Applied the suggestion in <sha>." Triage is unchanged: a suggestion doesn't make a thread FIX. Never use GitLab's **Apply suggestion** button: it commits on the remote and skips the tests.
- `review.json` now keeps each thread's `new_line` and `head_sha` (the commit the comment was made on).
- **Threads you already answered aren't triaged again** (#98). `/fetch-review` leaves out a thread when its last note is yours: a pipeline reply (a PUSH BACK, say), one you typed in GitLab, or a thread you started. It prints how many it skipped. When Duo or a teammate writes after you, the thread comes back. A new round starts only when a thread is new or has a new note since the last round, so a fetch with nothing new prints `Nothing new since round <n>` and uses up no round, even at `MAX_REVIEW_ROUNDS`. Open ASK threads with no new replies keep ASK without the review-responder reading their code again. The fetch now looks up your user with `glab api user`, and fails if it can't.
- **Replies are marked as the pipeline's** (#98). `reply-thread.sh` starts every reply it posts, on Duo threads and on `/review-mr` re-reviews, with `**[pipeline]**`, so teammates can tell it from one you wrote. Replies you type yourself are unchanged.
- **Adopt your own branch or MR** (ADR 0004, #96). `/start-task <clickup-id> --mr <iid>` or `/start-task <clickup-id> --branch <branch>` starts a delivery task on work you began outside the pipeline, so the pipeline can review and fix it before your teammates look. The branch keeps its name and commits, and the whole route runs on top of them. The planner reads the new `adopted-commits.md` and ticks the slices your commits already cover. At ship, the shipper updates your MR instead of creating one, keeping your title and description above its own sections. `--mr` refuses a teammate's MR (use `/review-mr`), one that isn't open, a fork MR and one targeting a branch other than `BASE_BRANCH`. A branch that diverged from origin is refused; one behind origin is fast-forwarded; one behind `BASE_BRANCH` is only reported, never rebased. New task state: `ADOPTED` (`state_adopted`, `state_set_adopted`). New `tests/test-start-task.sh`.
- `start-task.sh` now refuses to put a task on a different branch from the one it already has, instead of silently keeping the old one.
- Fixes from a code review of the three changes above:
  - `apply-suggestion.sh` runs on macOS's bash 3.2 again: it used `mapfile`, which bash 3.2 doesn't have. A new `tests/test-portability.sh` fails when any pipeline script uses a bash 4+ feature.
  - `apply-suggestion.sh` accepts a closing fence longer than the opening one, as Markdown does.
  - `/start-task <id> --branch <BASE_BRANCH>` is refused: the pipeline never works on the base branch.
  - `start-task.sh` stops with a message when it can't reach origin to look up the branch, instead of treating the branch as one only you have.
  - `/fetch-review` prints `Nothing new since round <n>` whenever no round starts, also when ASK threads are still waiting. The review-responder stops there if it has already triaged that round.
  - The planner's "the branch was adopted" note is now in every planner prompt for an adopted task, not only the first plan.

### Under the hood

- **One forge module talks to GitLab** (#103). The new `scripts/agent/forge-lib.sh` is the only code that runs `glab`, apart from `doctor.sh`'s `glab auth status`. It covers who you are, an MR's facts and summary, its threads, whether it can be reviewed or adopted, and the writes: create or update an MR, reply, resolve and post a thread. `start-review.sh`, `start-task.sh --mr`, `fetch-duo-review.sh`, `doctor.sh`, `create-mr.sh`, `reply-thread.sh` and `post-review-thread.sh` use it. Behaviour and messages are unchanged, with two exceptions: `/review-mr` and `--mr` now also refuse an MR GitLab returns without a state or target branch, and a failed GitLab write now says which step failed. `tests/test-portability.sh` fails when another script runs `glab`, and `tests/test-guard.sh` checks that sourcing the library is denied. The tests share one fake glab (`tests/lib/fake-glab/glab`) that answers from files and logs each write, in place of their own argv-matching stubs. New `tests/test-forge.sh`.
- Follow-ups to the forge module:
  - `/start-task <id> --mr <iid>` asks GitLab twice (who you are, and the MR with its title and description) instead of four times, using the new `forge_mr <iid> --with-text`.
  - `tests/test-portability.sh` now also catches a `glab` call on the same line as a message, such as `x="$(glab api …)"; echo done` or `echo "$(glab api …)"`. Before, it skipped any line containing `echo`, `printf` or `result`.
- **One Duo round module** (#106). The new `scripts/agent/duo-round-lib.sh` is the only code that knows a Duo round's formats:
  - which threads go into `review.json`
  - the round rule and its seen set
  - `review-triage.md`

  `fetch-duo-review.sh`, the router and `apply-suggestion.sh` use it.
  - The review-responder now writes `review-triage.md` from a template in its instructions: a `Round:` line and a `| Thread | File:line | Verdict | Reason | Commit |` table.
  - The router reads ASK threads from the Verdict column only. It stops with a message when a verdict isn't exactly `FIX`, `PUSH BACK` or `ASK`, or when `Round:` is missing. It used to count an `ASK` in any column and ignore an unknown verdict.
  - Task state keeps the round's seen set readably, as `REVIEW_SEEN=<thread>:<last note>,…`, in place of `REVIEW_IDS` checksums. A task already in a Duo round on v2.1.0 keeps its round when you upgrade, as long as its open Duo threads are the same ones as at its last fetch (any other set counts as a new round, as v2.1.0 counted it).
  - `fetch-duo-review.sh` refuses an option other than `--force`.
  - New `tests/test-duo-round.sh`.
- The router asks the ship gate for the verified commit (`gate_verified`) instead of reading `.work/<id>/verified-head` itself, so only `ship-gate.sh` knows where that commit is kept. `tests/test-gates.sh` fails when another script reads the file. Behaviour is unchanged.

## v2.1.0

A second route: **MR review** (ADR 0003). `/review-mr <iid>` reviews an MR that already exists, usually a teammate's, against its ClickUp spec, read-only, and posts only the findings you pick, each one after you confirm it. Also: the optional skills install on a first install again, and `install.sh --local` keeps the pipeline out of git.

**Not yet tried for real:** `/review-mr` on a live GitLab MR (placing a thread on a diff line is the least proven part: when it can't, the finding goes up as a general thread naming the file and line), and, with `--local`, Copilot loading `.github/instructions/agent-pipeline.instructions.md`. Pinned models are still unverified on a paid plan (#67).

### Upgrading to v2.1.0

1. From v2.0.0 (or any v1.2.x, see "Upgrading to v2" first), run `install.sh --update` from v2.1.0: `curl -fsSL https://raw.githubusercontent.com/SuperEjay/copilot-delivery-pipeline/v2.1.0/install.sh | bash -s -- --update`.
2. Merge each `<file>.new` it reports. The requirements, verifier and reviewer agents have a new "In an MR review" section: an MR review stops with a message while one of them lacks it. Delivery tasks aren't affected.
3. The installer lists the new settings your `.agent.env` doesn't set: `INSTALL_CMD`, `MR_REVIEW_MAX_FILES`, `MR_REVIEW_SKIP_PATTERN`. Copy any you want from `.agent.env.example`; the defaults work without them.
4. Commit the updated pipeline files (with `--local`, there's nothing to commit), fully quit and reopen VS Code, and check that `/review-mr` appears when you type `/`.

Tasks in progress carry on: a `state.env` without `KIND` reads as delivery.

### Changes

- **MR review, part 1: starting a review** (ADR 0003, #79). `/review-mr <iid> [clickup-id]` on the pipeline agent runs the new `scripts/agent/start-review.sh`. It checks the MR with `glab` and refuses merged and closed MRs; drafts are fine. It fetches `refs/merge-requests/<iid>/head`, so fork MRs work too, and checks that commit out into a **review worktree** at `.git/pipeline-reviews/mr-<iid>`. Test runners and linters run in your checkout can't see it there. The work folder is `.work/mr-<iid>/`. Your branch and uncommitted work are never touched, so a dirty checkout doesn't block a review. Run it again to move the worktree to the MR's new head. The router's MR review route comes in a later change (#81).
- The task state has a kind: `state_kind` prints `DELIVERY` or `MR_REVIEW`. A `state.env` without `KIND`, from any earlier version, reads as delivery. An MR review's file has no branch (`state_branch` says so) and no Duo round. New: `state_init_review`, plus `state_clickup_id` and `state_set_clickup_id` for the ClickUp id given at the start. That id is kept across runs, and a new one replaces it.
- The hook guard protects `.github/skills/review-mr/` like the other pipeline skills. New `tests/test-start-review.sh`.
- **MR review, part 2: the router's second route** (ADR 0003, #81). `next-stage.sh mr-<iid>` picks the route from the task kind. It reads the review worktree's head, not your HEAD, in its checks, its approvals and the run log. The stages: spec (requirements) → checks (verifier, in the worktree) → review (reviewer) → findings stop → post (reviewer, only the findings marked post) → end. Checks that fail don't stop the review and start no fix round: they become findings. The new stops are listed below. The run log, `status.md`, approvals and the stalled stop work as in delivery. The agents' "In an MR review" modes come next (#83, #85, and the verifier's).
  - **spec**: only when `requirements.md` says `Spec source: none`. You can reply with a ClickUp id or the ACs, or approve reviewing against the MR description, a weak spec check.
  - **focus**: only when the MR changes more than `MR_REVIEW_MAX_FILES` files. That's a new setting, default 40. Files matching the new `MR_REVIEW_SKIP_PATTERN`, lockfiles and generated files by default, don't count. Your choice goes in `focus.md`. Approving without one reviews the files with the most churn.
  - **findings**: always. Approving it needs post, debt or skip on every finding. A posted finding gets a `- **Thread:**` line in `code-review.md`, which doesn't bring this stop back.
- `start-review.sh` also stores the MR's target branch (`state_target_branch`) and fetches it: the router counts the MR's files from there. New `scripts/agent/set-review-spec.sh <iid> <clickup-id>` stores the ClickUp id you give at the spec stop and changes nothing else. The requirements agent runs it.
- **MR review, part 3: dependencies and checks in the review worktree** (ADR 0003, #80). When the worktree's lockfiles match your checkout's, `start-review.sh` links its `node_modules` to yours. When the MR changes a lockfile, it runs the new `INSTALL_CMD` setting (default `npm ci`) in the worktree instead. It installs once per lockfile version and logs to `.work/mr-<iid>/logs/install.log`. A failed install stops the review with the log's last lines. With `INSTALL_CMD` empty, nothing is installed.
- `run-checks.sh <task-id>` runs an MR review's checks in its review worktree: the task kind picks the folder, so a review's checks can't run on your HEAD by mistake. It records no verified commit there and prints `CHECKED <sha>` with the commit it checked. Delivery tasks run as before.
- **MR review, part 4: the verifier's MR review mode** (ADR 0003, #90). `verifier.agent.md` has an "In an MR review" section. It runs `run-checks.sh mr-<iid> all` once, in the review worktree, and writes `verification.md` with `Commit:` set to the checked MR head. Each failing check is listed with its failing lines, for the reviewer to turn into a high-severity finding. It adds no tests, changes and commits nothing, and leaves the acceptance criteria to the reviewer. The router's new `REVIEW_AGENTS` lists the agents with an MR review mode. An MR review stops with a message, before deciding anything, when one of them lacks its section. Delivery tasks aren't affected.
- **MR review, part 5: reading the MR's discussion** (ADR 0003, #82). For an MR review, `fetch-duo-review.sh mr-<iid>` writes `.work/mr-<iid>/threads.json` with every author's open threads: unresolved ones and plain comments, not system notes. Each keeps its replies and position, for the reviewer to read before writing findings. `DUO_USERNAMES` doesn't filter them, and no review round is counted or used up. A delivery task's Duo fetch is unchanged.
- **MR review, part 6: the spec, from ClickUp first** (ADR 0003, #83). `requirements.agent.md` has an "In an MR review" section, and the router's `REVIEW_AGENTS` now includes it.
  - **Where it looks:** the ClickUp id in the task state, then the MR's branch, title and description, then its commit messages (`CU-<id>`, `#<id>`). It never guesses.
  - **What it writes:** `requirements.md` always has a `Spec source:` line: `ClickUp <id>`, `MR description (weak)`, `ACs from the user` or `none`. `none` brings the spec stop. Gaps in the spec go under `## Spec gaps`, for the reviewer to raise as `spec-gap` findings. There are no open questions.
  - **New `.work/mr-<iid>/mr.json`:** `start-review.sh` saves the MR's title, description, branches and commit messages there, so the lookup reads one file.
  - **`clickup.sh` in an MR review:** `clickup.sh fetch mr-<iid>` fetches the stored ClickUp id into the review's own folder. `comment`, `status` and `attach` are refused for an MR review, and nothing is sent.
- **MR review, part 7: posting findings, and read-only enforced** (ADR 0003, #84).
  - **New `scripts/agent/post-review-thread.sh <iid> <CR-n>`** posts one finding marked post as its own MR thread, starting with `**[pipeline review] CR-n · <severity> · <category>**`. When the finding's `file:line` is in the MR's diff (an added line, or an unchanged line in a hunk), the thread sits on that line. Otherwise it's a general thread that names the location. The thread id goes back under the finding as `- **Thread:** <id>`.
  - **What it refuses:** a finding not marked post, one already posted, and an MR that moved on since the review. In that last case, run `/review-mr <iid>` again first.
  - **The hook guard asks you to confirm every post.**
  - **The guard keeps an MR review read-only.** The review worktree (`.git/pipeline-reviews/`) is a new protected kind, `review`: agents may read it and name it, but not change it. A git commit or push that names the worktree is denied, and so is one run from inside it. From inside it, so is a write to any file. `clickup.sh comment|status|attach` and `upload-evidence.sh` for an `mr-<iid>` task are denied, not just confirmed. The rest of your checkout is unaffected.
- **MR review, part 8: cleanup** (ADR 0003, #87). `/review-mr <iid> --done` (`start-review.sh <iid> --done`) removes the review worktree and the dependencies installed in it. It keeps `.work/mr-<iid>/`, and it needs no `glab`, so it works after the MR is merged. A worktree that linked to your `node_modules` loses only the link. `doctor.sh` WARNs about each review worktree whose MR is merged or closed, with its `--done` command. When it can't tell an MR's state, or `glab` isn't logged in, it prints an INFO line instead.
- **MR review, part 9: the review** (ADR 0003, #85). `reviewer.agent.md` has an "In an MR review" section, and the router's `REVIEW_AGENTS` now lists all three agents with an MR review mode.
  - **What it reads first:** the MR's open threads (`fetch-duo-review.sh mr-<iid>`). A point already raised goes under `## Already raised`, with "+1, see thread" only when there's new evidence.
  - **What it checks:** the diff against the spec. Failed checks become blocker or major findings, and spec gaps become `spec-gap` findings. It keeps to the focus you picked.
  - **What it decides:** post, debt or skip for each finding, with no fix and no route. It keeps `tech-debt.md` matching the debt decisions. It posts only what you approved, one finding at a time, and a post you decline becomes skip.
  - **The template:** the MR review `code-review.md` template has `- **Decision:** post | debt | skip`.
  - **`review-signals.sh mr-<iid>`** works in the review worktree. It compares the MR's head against its target branch, or on a later run covers only the commits since the last review. `--mark-reviewed` records the MR's head.
- **MR review, part 10: re-review after the author pushes** (ADR 0003, #86). Run `/review-mr <iid>` again: the worktree moves to the new head. With no new commits, the run ends at once. With new commits:
  - **What's reviewed:** the focus stop counts only the files changed since the last review. The reviewer reviews only the new code, with new CR numbers.
  - **Posted findings:** the reviewer marks each one `Status: verified` or `open`. Decisions already made aren't reopened.
  - **Replies:** after any new posts, the router has the reviewer reply on each verified finding's thread through `reply-thread.sh`, and you confirm each reply. `- **Replied:** yes|declined` is recorded and doesn't bring the findings stop back. The end line counts the verified findings.
  - **Never resolves a thread:** `reply-thread.sh mr-<iid> … --resolve` is refused by the script and the guard, and the guard asks you to confirm every reply on an MR review's thread.
- **MR review: fixes from the code review.**
  - **`review-signals.sh` checks ancestry for a delta.** It reviews only the commits since the last review when the reviewed head is still in the MR's history. After a force-push or rebase it reviews the whole MR again, instead of a range that would pull in the target branch's changes.
  - **The focus stop no longer passes silently.** When the MR's target branch can't be read, the router stops at `focus` (no approval passes it) and says to run `/review-mr <iid>` again, instead of counting 0 files.
  - **The guide says which ClickUp writes the guard denies** in an MR review: only for an `mr-<iid>` task id. A write naming the ClickUp id itself still only asks you to confirm.
  - **The README's Development list names the two new test files.**
- **One reader for findings.** The new `scripts/agent/findings-lib.sh` is the only code that reads or changes the findings in `code-review.md`. The router's two routes and `post-review-thread.sh` each had their own parser, with different rules; they use it now. New `tests/test-findings.sh` checks it against the reviewer agent's own templates.
  - **A choice list is undecided.** A finding left with the template's `post | debt | skip` (or `fix | debt | skip`) stops for you as undecided. Before, it read as post (or fix).
  - **`_pending_` is empty everywhere.** `post-review-thread.sh` refused a finding whose Thread line was `_pending_` as "already posted", while the router sent the reviewer to post it. Posting now replaces that line with the thread id.
  - **A finding ends at the next `##` or `###` heading.** A `# ` line inside it, such as a shell comment in a code block, doesn't end it. A `**Status:**` line in a later section, such as "Already raised", no longer counts as the last finding's. A field counts only at the start of a `- ` line or after ` · `, not quoted mid-sentence.
- **New `state_is_review <task>`** in `task-state.sh`: it succeeds, silently, only for an MR review, and a missing `state.env` counts as not one. The seven scripts that pick their MR review behaviour from the task kind use it, in place of three different checks. `set-review-spec.sh` gives one message for a missing review and for a delivery task: "No MR review of !<iid> yet".
- **The guard protects the review worktree with a separate git folder too.** Its protected entry is now `pipeline-reviews/mr-*/` under any git folder, not only `.git/pipeline-reviews/`; a project folder of your own named `pipeline-reviews/` stays editable. With `git init --separate-git-dir` (a git folder like `repo.git`), the worktree is at `repo.git/pipeline-reviews/mr-<iid>`, and agents could change it. The guard, doctor and start-review tests now take the path from `review_worktree`, so a rename in `config.sh` that the guard or doctor misses fails them.
- **Docs: the MR review route** (ADR 0003, #88).
  - **README:** a "Review a teammate's MR" section.
  - **Guide:** `docs/agent-pipeline.md` has a new section, "MR review (a teammate's MR)": how it starts, the stages and their three stops, posting, re-review, read-only enforcement, `--done`, and the settings `INSTALL_CMD`, `MR_REVIEW_MAX_FILES` and `MR_REVIEW_SKIP_PATTERN`. Its file list and its hooks table include the review skill, scripts and guard rules.
  - **Agent rules:** the rules every agent gets (`copilot-instructions.md`) say an MR review is read-only.
  - **Tests:** `tests/test-orchestrator.sh` checks that the docs cover the route. Several test helpers no longer pipe into `grep -q`, which with `pipefail` could fail at random.
- **Fix: the ponytail and caveman skills failed on a first install.** Run by a person (not an agent), `skills add` stopped at its "Select skills" prompt and, with no terminal on stdin, installed nothing, so the installer warned `ponytail install failed` and `caveman install failed`. The installer now passes `skills add` its own `-y`, and a failure's warning gives the command to run later. New check in `tests/test-install.sh`.
- **README:** covers the MR review route throughout: the intro, `glab`'s requirement, `/review-mr` in the post-install check and the first steps, and where the optional skills go (`.agents/skills/`, `skills-lock.json`) and how to commit them. The guide's setup check lists `/review-mr` too.
- **New `install.sh --local`: keep the pipeline out of git.** The pipeline's exact paths, the optional skills and the usual `.work/`, `.agent.env` lines go in a `BEGIN/END agent-pipeline` block in `.git/info/exclude`, never committed. The rules go in their own file, `.github/instructions/agent-pipeline.instructions.md` (`applyTo: "**"`), so neither `copilot-instructions.md` nor `.gitignore` changes and the tree stays clean for `start-task.sh` and the ship gate. The manifest records `# local`, so `--update` stays local, and `--uninstall` removes the file and the block. `--update --local` on a committed install prints the `git rm --cached` command and flags a leftover rules block. A first install asks about it, defaulting to no (`--yes` keeps the shared default). The hook guard protects the new rules file. README: "Keep the pipeline out of git".

## v2.0.0

The auto run is the main path, with manual mode as the fallback (ADR 0002), ahead of VS Code removing the Local harness in February 2027. Tried first as the pre-releases v2.0.0-rc.1 and v2.0.0-rc.2.

**Pinned models are still unverified.** ADR 0002 planned a check on a paid Copilot plan before this release; v2.0.0 went out without it (issue #67 keeps it as a follow-up). On a plan where they don't hold, each stage runs on the session's model: the run still works, at a different cost. See "Pinned models in an auto run" in `docs/agent-pipeline.md`.

### Upgrading to v2

1. Be on v1.2.0 or later. From an older install, update to v1.2.2 first: `curl -fsSL https://raw.githubusercontent.com/SuperEjay/copilot-delivery-pipeline/v1.2.2/install.sh | bash -s -- --update`. `--update` refuses anything older, even with `--force`.
2. Run `install.sh --update` from v2.0.0: `curl -fsSL https://raw.githubusercontent.com/SuperEjay/copilot-delivery-pipeline/v2.0.0/install.sh | bash -s -- --update`.
3. Merge each `<file>.new` it reports into the file you changed. In an agent file, drop the `handoffs:` block: the agents have none now.
4. If you changed a pipeline script, check it doesn't call `load_state` or `set_state`. They now stop the script; use the `state_*` functions in `scripts/agent/task-state.sh` (listed below).
5. On Windows, move to WSL: Git Bash is unsupported.
6. Run `scripts/agent/doctor.sh` and fix every FAIL.

Tasks you started on v1.2.x carry on: their `.work/<id>/` files are read as before. From v2.0.0-rc.1 or rc.2, step 2 is all there is.

### Changes

- **Breaking: the stage agents have no handoffs** (ADR 0002). The `handoffs:` buttons only ever showed in the Local harness, which VS Code removes in February 2027, and never in Copilot (Agent Host) sessions. In manual mode, move on with each agent's **Next:** line, as before; the agents' steps that said "use the handoff" now point to the matching **Next:** line. If you changed an agent file, `--update` keeps yours and writes the new one next to it as `<file>.new`: drop its `handoffs:` block when you merge. `tests/test-agents.sh` now fails on any stage agent with a `handoffs:` block.
- **Breaking: `load_state` and `set_state` are removed** (ADR 0002), deprecated since v1.2.0. No pipeline script calls them. If a script you changed still does, switch it to the `state_*` functions in `scripts/agent/task-state.sh`: `state_branch`, `state_mr_iid`, `state_review_round`, `state_review_ids` and `state_reviewed_sha` to read; `state_init`, `state_set_mr_iid`, `state_set_review` and `state_set_reviewed_sha` to write. A call to either name now stops the script with exit code 1 and a message saying so. It doesn't rely on bash's "command not found", which wouldn't stop a script without `set -e`, such as `review-signals.sh` or `run-checks.sh`, so it would run on with empty values.
- **Breaking: `--update` accepts v1.2.0 and later only** (ADR 0002). It reads the installed version from the first line of `.github/agent-pipeline.manifest`. For an older install, or one whose version it can't read, it stops before downloading or changing anything and says to update to v1.2.2 first (`curl -fsSL https://raw.githubusercontent.com/SuperEjay/copilot-delivery-pipeline/v1.2.2/install.sh | bash -s -- --update`), then run the update again. `--force` doesn't skip this. A fresh install isn't affected.
- **A task started on v1.2.x carries on after the update.** Its `.work/<id>/` files are read as before. `tests/test-next-stage.sh` runs v1.2.2's own router up to an approved requirements stop, then the current one, which moves on to the planner.
- `next-stage.sh` no longer has a separate check for a task started before auto run. A `plan.md` with no `## Stop flags` heading is now the same plan stop as one missing a line: it names the missing line, and the planner adds it.
- `tests/test-install.sh` installs the real v1.1.0, v1.2.0, v1.2.1 and v1.2.2 releases with their own installers and updates each with the current one: v1.1.0 (with and without `--force`) and a manifest with no readable version are refused without changing a file, and each v1.2.x updates. The checks on kept files and `.new` copies now run on a v1.2.2 install instead of v1.1.0.
- **The run log.** `next-stage.sh` appends one line to `.work/<id>/run.log` for each decision it prints and each approval it records: `<UTC time> <run|stop|end|approve> <agent or stop id, - for end> round=<n>/<max> head=<short HEAD>` (ADR 0002). A refused approval adds nothing. The file isn't one of the run's inputs, so writing it never hides a stalled stage. A task started on v1.2.x has no run log yet; it starts with the next decision. The hook guard protects it like `status.md`: agents may read it, but edit tools and shell writes are denied. A product file named `run.log` elsewhere stays editable.
- **`install.sh` run by a relative path installs from its clone.** Run as `./install.sh /path/to/project`, it looked for its clone only after moving into the project, where `./install.sh` no longer pointed anywhere. So it downloaded the release named in the script from GitHub instead of using the clone's `payload/`, or failed with no network. It now finds its clone first. An absolute path, such as the README's `/tmp/cdp/install.sh .`, and `curl … | bash` work as before.
- **`scripts/agent/doctor.sh` checks a setup and changes nothing.** One line per check, PASS, WARN, FAIL or INFO: the required tools (`git`, `curl`, `jq`, `glab`, `node`, `npx`) and the optional ones, `glab` logged in, `CLICKUP_API_TOKEN` exported and its value in no tracked file and not in `.agent.env`, settings `.agent.env` doesn't set, CRLF line endings in `scripts/agent/`, the hook guard blocking a test `git push` (and `PIPELINE_GUARD=off`), VS Code 1.106 or later, and Windows with Git Bash. It exits 1 on any FAIL and never prints the token. Pinned models can't be checked by a script, so it says how to check them by hand. The installer runs it at the end, in place of its own tool list and guard test; a FAIL there doesn't fail the install. New `tests/test-doctor.sh`.
- Docs: the README and `docs/agent-pipeline.md` lead with the auto run. The guide's sections are now "Daily use: auto run" and "Manual mode (fallback)" (were "Hands-off: auto run" and "Daily use: stage by stage"). Windows with Git Bash is marked unsupported, WSL is the supported way, and the alert settings are optional.
- **`curl … | bash` runs the whole installer again.** Piped from curl, the installer reads its own script from stdin, and `npx skills add` (for the optional skills, which `--yes` turns on) read the rest of it, so everything after the skills step silently never ran: in v2.0.0-rc.1 that was the `doctor.sh` check and the "Done. Next steps" lines. `npx` and `doctor.sh` now get no stdin. `tests/test-install.sh` pipes the installer into bash with an `npx` and a `glab` that read stdin, and checks it reaches the end.

## v1.2.2

Docs: a clearer README and an up-to-date pipeline diagram. To upgrade from v1.2.1, run `install.sh --update`; there are no other steps.

- **Docs: install and update steps for each platform.** The README lists what the pipeline needs and how to install it on macOS, Linux, Windows with WSL (recommended) and Windows with Git Bash (unverified: the hook guard may not run there). It has a step-by-step first-time install and a walkthrough for updating an existing install to a new version. On Windows, add `*.sh text eol=lf` to `.gitattributes` so bash doesn't fail on CRLF line endings.
- Docs: the pipeline diagram at the top of `docs/agent-pipeline.md` shows the auto run: the pipeline agent, `next-stage.sh`, each stop, and the Duo round loop.

## v1.2.1

A fix to the pre-ship stop, and docs and code cleanups. To upgrade from v1.2.0, run `install.sh --update`; there are no other steps.

- **The pre-ship approval covers `auto-decisions.md`.** The pre-ship stop asks you to review it, but a change to it after you approved didn't bring the stop back, so the shipper could ship on decisions you never saw. It's now part of the stop's checksum, and of the inputs that tell a stalled stage from one that has new work. A task already approved at pre-ship gets the stop once more after the update.
- Docs: `--update` replaces everything between the `BEGIN/END agent-pipeline` markers in `.gitignore` and `.github/copilot-instructions.md`, so a line you add inside them is lost. The README and `docs/agent-pipeline.md` now say to keep your own lines outside the markers.
- Cleanups in `scripts/agent/next-stage.sh`, with no behaviour change: the six-slice plan limit is one constant (`MAX_PLAN_SLICES`), the stage agents are one list (`STAGE_AGENTS`), one parser reads `Key:` lines, and some names are clearer. If you changed `next-stage.sh`, `--update` writes the new version next to it as `next-stage.sh.new` to merge.

## v1.2.0

Auto run: pick the **pipeline** agent and `/start-task`, and the stages run one after another, stopping only where a human decision is needed. The guard is hardened, and installs from v1.1.0 have an upgrade path. Stage-by-stage use is unchanged.

### Upgrading from v1.1.0

1. Run `install.sh --update`.
2. Merge each `<file>.new` it reports into the file you changed (or re-run with `--force` to take the new version; yours is kept as `.bak`). An auto run needs every stage agent's `## In an auto run` section, and `next-stage.sh` names any agent file that lacks it.
3. Finish tasks you started before the update stage by stage. Their `plan.md` has no `## Stop flags`, so `next-stage.sh` won't run them.
4. Optional: add `MAX_AUTO_FIX_ROUNDS` (default 2) to `.agent.env`. `--update` lists every setting in `.agent.env.example` that your `.agent.env` doesn't set, and never writes the file.

### Changes

- **The guard catches `>|` and `>&file` redirects.** `echo x >| scripts/agent/config.sh` (clobber) and `cat a >&scripts/agent/config.sh` (csh-style) got past the shell check for pipeline config and task state (`.work/<id>/status.md`, `state.env`), because the command was split at `;`, `|` and `&` before the redirect was matched, cutting the redirect in half. Redirects are now matched on the whole command.
- The hook guard now blocks agents from changing pipeline config through the shell too (redirects, `sed -i`, `cp`, `mv`, `rm`, `chmod`, `tee`, inline `python -c` and similar), not only through edit tools. Before this, a shell command could rewrite or switch off the guard itself.
- New `tests/test-guard.sh`: a table of tool calls and the decision the guard must make for each.
- **Only verified code is pushed.** `run-checks.sh <id> all` records the commit it passed on a clean tree in `.work/<id>/verified-head`, and `create-mr.sh` and `push-branch.sh` refuse to push anything else. Before this, the shipper only checked that `verification.md` said PASS, so a commit added after verification could ship unverified.
- **Evidence is tied to a commit.** `approve-evidence.sh` records the full commit, and `upload-evidence.sh` (and so a new MR) refuses if HEAD has moved on since. Existing approvals with a short sha still work.
- **Duo fixes are verified before they're pushed.** The review-responder commits fixes and hands over to the verifier; it pushes and replies on the threads only after the verifier passes (`Push and reply <id>`).
- **Re-fetching a Duo review doesn't use up a round.** `fetch-duo-review.sh` counts a new round only when the set of threads changes.
- The verifier now commits its new tests first and runs `run-checks.sh all` last.
- New `tests/test-gates.sh` covers the push gates and round counting.
- The ship gate's rules (right branch, verified commit, evidence approved at that commit) now live in one module, `scripts/agent/ship-gate.sh`, and the evidence approval record is written and checked only in `evidence-lib.sh`. No behaviour change: `create-mr.sh` and `push-branch.sh` call the gate, `run-checks.sh` records verification through it, and `tests/test-gates.sh` tests the rules against the gate directly.
- **One protected-path table in the hook guard.** Every protected path (secrets, the verified-commit and evidence records, pipeline config) is listed once, and the shell and edit-tool checks both use it. `pre-tool-guard.sh --list-protected` prints it, and `tests/test-guard.sh` checks every entry from it. The shell check now starts a match at a path segment like the edit check does, so names that only contain a protected path (`my.agent.env`, `vendor/myscripts/agent/`, `.npmrc.example`) are no longer blocked from the shell.
- **The guard catches Windows paths.** Edit and read tools that pass `C:\repo\scripts\agent\x.sh`-style paths were not matched against protected paths; backslashes are now treated as `/`.
- **The guard ignores case for protected paths**, so `Scripts/Agent/x.sh` or `.AGENT.ENV` on macOS and Windows are blocked like their lower-case names.
- **state.env is read, never run.** New `scripts/agent/task-state.sh` reads `.work/<id>/state.env` through one reader per key (`state_branch`, `state_mr_iid`, `state_review_round`, `state_review_ids`, `state_reviewed_sha`). It parses the file instead of sourcing it, so a branch name like `feature/T1-$(cmd)` is just text, and a line like `BASE_BRANCH=x` or `MAX_REVIEW_ROUNDS=99` no longer overrides `.agent.env`. Writes go through it too (`state_init`, `state_set_mr_iid`, `state_set_review`, `state_set_reviewed_sha`), which refuse a value containing a newline, so the file's layout lives in one place. Every script reads and writes the file only through it; `push-branch.sh` no longer depends on `$BRANCH` leaking out of the ship gate. A missing MR or branch gives the same message from every script. Existing state.env files read as before. `load_state` and `set_state` are deprecated but still work, now parsing too, so a script you changed (which `--update` keeps) can't run code from state.env either; they go in a later release. New `tests/test-task-state.sh`, and `tests/test-gates.sh` checks the scripts end to end.
- **Agents can't change state.env.** The hook guard has a new `state` kind of protected path: agents can read `.work/<id>/state.env` (from the shell too), but edit tools and shell writes are denied, so an agent can't reset `REVIEW_ROUND` to get past `MAX_REVIEW_ROUNDS` or change the task's branch. The entry is any path segment named `state.env`, so an app file with that name is protected too.
- **Agents can't source the pipeline's scripts.** `bash -c 'source scripts/agent/config.sh; source scripts/agent/ship-gate.sh; gate_record_run T1 0'` recorded HEAD as the verified commit without running any checks, and `approval_write` or the task-state writers could be called the same way, because the command never named a protected file. The guard now denies `source` or `.` of anything under `scripts/agent/`.
- **The auto run's router.** New `scripts/agent/next-stage.sh <id>` decides what an auto run does next from the files in `.work/<id>/`, the task state, HEAD and the verified commit, and prints one line: `run <agent> <prompt>`, `stop <stop-id> <reason>` or `end <reason>`. It encodes the stop rules of ADR 0001: requirements always stop; the plan stops only on a Stop flag or more than 6 slices (otherwise it's recorded in `auto-decisions.md`); code review stops only for findings without a decision or routed to requirements or re-plan; fix loops stop after `MAX_AUTO_FIX_ROUNDS` (new, default 2); one pre-ship stop covers the evidence, `mr.md` and the push; an open MR ends the run; a Duo round stops only for ASK threads and the push. `next-stage.sh <id> approve` records an explicit approval, tied to a checksum of what the stop was about, so a change afterwards brings the stop back. A stage that ran and changed nothing stops the run instead of looping. The script keeps `.work/<id>/status.md`. The orchestrator calls it (below).
- The planner writes a `## Stop flags` section in plan.md, the verifier writes the HEAD it checked on a FAIL too, the evidence manifest has a `Commit:` line, and review-triage.md has `Round:` and `Replied: yes` lines, so `next-stage.sh` can read where a task stands.
- New `tests/test-next-stage.sh`.
- **Stage agents know an auto run.** Each of the eight agents has an **In an auto run** section, used only when the prompt starts with `AUTO RUN`. In that section the agent never asks the user and writes its questions and decisions into its `.work/` files. When it can't finish, it returns `**Result:** blocked: <why>` (the run then stops), and it always ends with a `**Result:**` line instead of `**Next:**`. The reviewer sets each Decision from its Recommend and logs it to `auto-decisions.md`. It leaves a finding `_pending_` for the user when the recommendation is unclear, or when it's a blocker recommended debt or skip. The planner records blocking questions as Requirement gaps instead of stopping. The shipper runs twice: once to write `mr.md`, then to ship after the pre-ship stop. The review-responder commits Duo fixes without waiting for an OK and leaves ASK threads for the duo stop. Every agent sets `include-custom-instructions: true`, so `copilot-instructions.md` reaches it as a subagent. Manual use and the handoffs are unchanged. New `tests/test-agents.sh` checks the agent files.
- **The orchestrator.** New `pipeline` agent (`.github/agents/pipeline.agent.md`, GPT-6 Luna) drives an auto run: pick it and run `/start-task`, and it follows `next-stage.sh`, running each stage agent as a subagent by name with the prompt word for word and the stage's model named on every call. At a stop it shows a `⏸ DECISION NEEDED` block with the reason, the last stage's **Result:** line and the replies it accepts. Only a reply that is nothing but an approval runs `next-stage.sh <id> approve`; anything else goes to the stage the stop is about as feedback. `/fetch-review`, `Run <id>` or `Continue <id>` resume a run. It changes no files, and warns once that Auto in the model picker cancels pinned models. `/start-task` and `/fetch-review` hand over to it when it's picked. The guard denies `next-stage.sh` from a subagent, so a stage can't approve a stop itself. New `tests/test-orchestrator.sh`.
- **`/start-task` and `/fetch-review` stop on any script failure** before handing over, passing the script's message on, so the pipeline agent never runs the loop on stale files. `/fetch-review <id> --force` now passes `--force` on (only when you typed it) to get past `MAX_REVIEW_ROUNDS`. The round limit is not a stop: the pipeline agent shows the message, with no decision block. Both skills' descriptions mention the auto run.
- **Agents can't forge a stop approval.** `next-stage.sh` keeps approvals in `.work/<id>/status.md` as `Approved <stop-id>: <checksum>` lines, and an agent could add one with an edit tool or a shell redirect. The hook guard now protects `.work/<id>/status.md` like `state.env`: agents may read it, but edit tools and shell writes are denied, and `next-stage.sh` stays its only writer. Protected-path entries can now use `*` for one path segment (`.work/*/status.md`), so only that file is protected: a product file such as `docs/status.md` stays editable. Paths are squashed before matching, so `.work//T-1/status.md`, `/./` or `<dir>/..` don't get past any protected path.
- **Docs: the auto run.** `docs/agent-pipeline.md` has a "Hands-off: auto run" section: starting with **pipeline** and `/start-task`, each stop and what to reply, `status.md`, `auto-decisions.md`, `MAX_AUTO_FIX_ROUNDS`, resuming, the warning against Auto in the model picker, and optional alert settings for `.vscode/settings.json`. Pinned models and the alerts are unverified (ADR 0001). The stage-by-stage flow is still documented.
- **The guard splits commands the same way on macOS.** It used to split a command at `;`, `|` and `&` with `sed`, writing `\n` in the replacement. BSD/macOS sed may write a literal `n` for that, which leaves the command whole. A subagent's `cat x; scripts/agent/next-stage.sh T-1 approve` then looked like a single `cat` that only reads, so the subagent could approve a stop, and harmless commands like `rm -rf .work/T-1/tmp && scripts/agent/run-checks.sh T-1 test` were denied. The split is now done in bash, without sed. `tests/test-guard.sh` runs these cases against a fake sed that behaves like BSD sed.
- **`--update` writes `<file>.new` next to a file you changed.** It still keeps your version, and now puts the new one beside it to merge, refreshed on each update and deleted by `--force` (or once your file matches it). `*.new` is in the managed `.gitignore` block, and `--update` now refreshes that block, so an older install gets the lines added since.
- **`--update` lists settings your `.agent.env` doesn't set** that `.agent.env.example` has, such as `MAX_AUTO_FIX_ROUNDS`. It never writes `.agent.env`.
- **`next-stage.sh` checks first that the task can use an auto run.** It exits 1, with no stop, when a stage agent file is missing or has no `## In an auto run` section (naming the file, and its `.new` if there is one), or when `plan.md` has no `## Stop flags` heading (a task started before auto run: finish it stage by stage). Before this, both ended in a plan stop that no approval could pass. A `## Stop flags` heading missing a line is still that stop.
- `tests/test-install.sh` updates a real v1.1.0 install (`git archive a7f97a2`) with the current installer, and skips that case when the commit isn't in the clone.

## v1.1.0

Works with Copilot (Agent Host) sessions, the default in current VS Code.

- `/start-task` and `/fetch-review` are now **agent skills** (`.github/skills/`) instead of prompt files, which only the Local harness loads (Copilot harness sessions, including those in Agent Host, use skills for slash commands). `--update` removes the old prompt files.
- Every agent ends its reply with a **Next:** line naming the next agent to pick and what to say, because handoffs are not supported in Copilot harness sessions, including those in Agent Host. The buttons stay for Local-harness sessions.
- The requirements agent can start from just a task id (`Analyse <id>`) and make the slug itself.
- The hook guard also protects the pipeline's own skills from agent edits.

## v1.0.0

First release.

- **Agents:** requirements, planner, implementer, verifier, reviewer, evidence, shipper, review-responder, each with a pinned model.
- **Integrations:** ClickUp via its REST API (`clickup.sh`), with no MCP needed; GitLab MRs and GitLab Duo review loop via `glab`.
- **Your checkpoints:** screenshot evidence with a user-only approval gate (SHA-256 fingerprints); code review with fix routing (quick, re-plan or requirements) and local-only tech debt.
- **Hooks:** a pre-tool guard (asks before anything publishes; blocks secrets, destructive git, raw pushes and test commands, and pipeline edits) and a post-edit formatter.
- **Installer:** install, update (keeps your changes), force, uninstall.
