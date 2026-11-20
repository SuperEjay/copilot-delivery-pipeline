---
status: accepted (2026-11-20, after the MR review grilling)
---

# A second route: MR review

Until now the pipeline has one route, **delivery**: `/start-task <clickup-id> <slug>` creates a branch and runs requirements through to the shipped MR and Duo's review. Teams also need the other side of that: reviewing an MR that already exists, usually one a teammate wrote by hand or with another tool. The reviewer stage already does a deep review, but only of the pipeline's own branch, with `requirements.md` and `plan.md` already in place.

**MR review** is a second route through the same orchestrator and router. It reviews any open MR against its spec and reports bugs, technical debt and improvements. It never changes the MR's code.

## Decisions

- **How it starts:** `/review-mr <iid>` on the `pipeline` agent, as an auto run. `<iid>` is the MR's number within its project (the `!142` in GitLab). Any MR is accepted, open or draft, including fork MRs (fetched through `refs/merge-requests/<iid>/head`). Merged and closed MRs are refused.
- **Its own work folder and kind.** A review lives in `.work/mr-<iid>/`. Its task state records `KIND=MR_REVIEW`, the MR iid, the reviewed head commit and the ClickUp id when one is found. It has no branch and no Duo round. The router (`next-stage.sh mr-<iid>`) picks the route from the kind. A delivery task without a kind is a delivery task, so existing `.work/` folders keep working.
- **A review worktree.** The MR head is checked out into a separate git worktree, so the user's branch and uncommitted work are never touched. Dependencies are symlinked from the main checkout unless the MR changes a lockfile; then a new `INSTALL_CMD` setting (default `npm ci`) installs them fresh. `run-checks.sh` takes a working directory.
- **Checks are findings, not a gate.** Lint, type check and test failures on the MR head become high-severity findings, and the review goes on. (The delivery reviewer stops unless verification passed, because there the pipeline wrote the code and can fix it.)
- **The spec comes from ClickUp first.** The requirements agent, in an MR-review mode, finds the ClickUp id in the MR's branch name or description. Failing that, it uses an id the user passes in, and failing that, the MR description alone. It raises no open-question stop: gaps in the spec become findings tagged `spec-gap`.
- **The same two agents, a new mode each.** The requirements and reviewer agents each get an "In an MR review" section, so reading ClickUp and the review checklist each stay in one place. The reviewer reads the MR's open discussion threads (people and Duo) first and doesn't repeat what is already raised. `fetch-duo-review.sh` learns to fetch every author's threads without counting a review round.
- **Read-only, enforced by the guard.** In an MR review the guard blocks edits, commits and pushes in the review worktree, and any write to ClickUp. The only thing that leaves the machine is a posted finding.
- **Stops:**
  - **Spec stop**, only when the spec fell back to the MR description or no ClickUp task was found.
  - **Focus stop**, only when the MR changes more than `MR_REVIEW_MAX_FILES` files (default 40, lockfiles and generated files not counted). The user picks what to review; the default is the files with the most churn.
  - **Findings stop**, always: for each finding the user picks **post**, **debt** (parked locally in `tech-debt.md`) or **skip**.
  - **Publish confirmation** for each posted finding, through the guard.
- **Posting.** Each posted finding is its own MR discussion thread, on the diff line when its location is inside the diff and general otherwise, and starts with `**[pipeline review] CR-n · <severity> · <category>**` so the author can tell it is AI-assisted. There is no summary comment. Posting goes only through a new `post-review-thread.sh`.
- **Re-review.** Running `/review-mr <iid>` again reviews only commits since the reviewed head, checks whether its own posted threads were addressed, marks them `verified` and, with the user's confirmation, replies on the thread. It never resolves a thread: that stays with the author and the team.
- **Cleanup.** The worktree is kept for re-reviews. `/review-mr <iid> --done` removes it. `doctor.sh` lists review worktrees of MRs that are merged or closed.
- **One run per chat.** An MR review can run while a delivery task is in progress, in a second chat; they share nothing but the repository.

## Considered options

- **Let the route fix the MR and push to its branch:** pushing to someone else's branch clashes with the ship gate and the verified commit, which assume the pipeline owns the branch. A fixing route can come later, as its own decision.
- **Keep findings local only:** this matches the delivery reviewer, but a review of a teammate's MR is only useful if the author sees it. Posting by choice, with a confirmation each, keeps the user in charge.
- **One new `mr-reviewer` agent:** simpler to wire, but it would copy the ClickUp reading and the review checklist, which would then drift apart.
- **Check the MR out in place, or read the diff only through `glab`:** in place needs a clean tree and disturbs the user's work; diff-only can't read surrounding code or run checks.
- **Call it "verifier":** Verifier is already the stage that runs the project's checks.

## Consequences

- **The router gets a second route.** `next-stage.sh` now branches on the task kind, and its tests cover both routes.
- **The pipeline publishes something new.** Until now it published only the user's own MR, evidence and replies to Duo. Now it can post review threads on other people's MRs, under the user's GitLab account.
- **Disk and install time.** Each review worktree is a full checkout, and an MR that changes a lockfile pays for a fresh install.
- **Token cost on Copilot Free.** Large MRs are capped by the focus stop. Re-reviews look only at new commits.
