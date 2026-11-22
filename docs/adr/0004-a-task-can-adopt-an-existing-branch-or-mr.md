---
status: accepted (2026-11-23, after the adopt grilling; #96)
---

# A task can adopt an existing branch or MR

Until now a delivery task always started from scratch: `/start-task <clickup-id> <slug>` made `<BRANCH_PREFIX>/<id>-<slug>` from `origin/<BASE_BRANCH>`, and only work done inside the pipeline went through its fix loop. Users also make MRs by hand, and want the pipeline to review and *fix* those before teammates look. `/review-mr` can't: it is read-only by design (ADR 0003).

An **adopted task** is a delivery task that starts on a branch the user already has: `/start-task <clickup-id> --branch <branch>`, or `/start-task <clickup-id> --mr <iid>` for the user's own open MR.

## Decisions

- **The same route, not a new one.** An adopted task is `KIND=DELIVERY` with `ADOPTED=mr|branch` in its task state. The branch keeps its name and commits. The whole delivery route runs on top of them: requirements, plan, build, verify, review and the fix loop, evidence, pre-ship, ship, then Duo rounds.
- **The MR's iid is not recorded when adopting.** The router sends a task with `MR_IID` straight to the Duo round, which would skip verify, review and evidence: the very checks the user wants. So adopting records nothing about the MR. At ship, `create-mr.sh` finds the open MR by its source branch and updates it (the push gate only; no new-MR evidence gate), and records `MR_IID` then.
- **The planner credits existing commits.** `start-task.sh` writes `adopted-commits.md` (the branch's commits and changed files; the planner can't run git). The router tells the planner the branch was adopted, and it ticks the slices those commits already cover, leaving only real gaps to build.
- **Only your own MR.** `--mr` refuses an MR by someone else (pointing at `/review-mr`), one that isn't open, one from a fork (the pipeline pushes to origin), and one targeting a branch other than `BASE_BRANCH`. `--branch` has no author check.
- **Your MR text is kept.** `--mr` saves the MR's title and description to `adopted-mr.md`. The shipper keeps both, word for word, and adds its own sections below a `---` line.
- **Branch state:** a dirty tree is refused; a branch only on origin is checked out tracking it; a local branch behind origin is fast-forwarded; one that diverged from origin is refused, because pushes are never forced. A branch behind `origin/<BASE_BRANCH>` is only reported: rebasing or merging it stays the user's call.
- **One branch per task.** Running `/start-task` again for a task on another branch is refused, for adopted and ordinary tasks alike.
- **A ClickUp id is still required** (#97 is about adopting without one).

## Considered options

- **Record the MR iid at adopt time and change `check_duo`:** the router would need a second "MR open but not yet checked" state. Leaving `MR_IID` unset reuses the existing route and gates unchanged.
- **Start at review with a made-up `plan.md`:** cheaper, but it loses the requirements and the planner's check of which ACs the branch doesn't meet yet.
- **A third route or a new skill:** adopting ends in the same fix loop and ship as delivery, so a separate route would copy it.
- **Let `/review-mr` fix your own MR:** ADR 0003 keeps it read-only; mixing "report on someone's MR" with "push to my branch" in one route would blur the line the guard enforces.

## Consequences

- **What a task is changes.** A delivery task's branch may have commits the pipeline didn't make, and its branch name may not follow `BRANCH_PREFIX`.
- **An adopted MR gets a full run's token cost**, requirements and planning included, even when the branch is nearly done.
- **The shipper changes an existing MR's description**, keeping the user's text above its own sections.
