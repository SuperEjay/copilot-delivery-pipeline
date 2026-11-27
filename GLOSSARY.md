# Otto

A pipeline of Copilot agents that takes a ClickUp task from requirements to a reviewed GitLab merge request, with the user approving every step that publishes anything.

## Language

### Shipping

**Ship gate**:
The check a commit must pass before the pipeline pushes it: the task's branch is checked out, HEAD is the verified commit, and for a new merge request, evidence was approved at that same commit.
_Avoid_: push guard, push check

**Verified commit**:
The commit that last passed every check on a clean tree. It is the only commit the pipeline will push.
_Avoid_: green commit, checked commit

**Evidence approval**:
The user's sign-off on a specific set of evidence files at a specific commit. It becomes invalid if any approved file changes or HEAD moves.
_Avoid_: evidence sign-off, approval stamp

### Running a task

**Auto run**:
One pass of a task through the pipeline where stages follow each other without the user choosing the next agent, until the next stop.
_Avoid_: autopilot, continuous mode, YOLO mode

**Orchestrator**:
The agent that drives an auto run. It starts each stage agent as the router decides, shows the user each stop, and is the only agent that talks to the user during the run. It changes no files itself.
_Avoid_: coordinator, conductor, main agent

**Router**:
The script that decides, from a task's files, which stage of an auto run comes next, or that the run stops or ends. It alone keeps the run's status, including the user's approvals of stops.
_Avoid_: dispatcher, scheduler

**Stop**:
A point in an auto run where the pipeline waits for a human decision. Only an explicit approval moves the run on.
_Avoid_: checkpoint, pause, gate (a gate is enforced by scripts; see Ship gate)

**Auto-decision**:
A decision the pipeline made on the user's behalf during an auto run under a rule the user agreed to, recorded so the user can review it before shipping.
_Avoid_: default, implicit approval

**Task state**:
The scripts' record of a task in `.work/<id>/state.env`: its kind (delivery or MR review), its branch, merge request and Duo review round, and for an MR review its ClickUp task and target branch instead of a branch and round. Scripts read and write it only through `task-state.sh`; it is data, never run as code.
_Avoid_: state file, task env

**Run log**:
The router's record of an auto run in `.work/<id>/run.log`: one line for each decision it prints and each approval it records, only ever appended. Only the router writes it; it is not one of the inputs that tell a stalled stage.
_Avoid_: history, audit log, trace

**Adopted task**:
A delivery task started on a branch the user already has, with `/start-task <clickup-id> --branch <branch>` or, for their own open MR, `--mr <iid>` (ADR 0004). It runs the whole delivery route on top of the existing commits; the MR is recorded only when the shipper updates it.
_Avoid_: imported task, takeover

**MR review**:
The pipeline's second route: a read-only review of an existing merge request, usually a teammate's, against its spec, started with `/review-mr <iid> [clickup-id]`. It finds bugs, technical debt and improvements, and posts only the findings the user picks. It never changes the MR's code.
_Avoid_: verifier, MR verification, PR review

**Duo round**:
One fetch's set of Duo threads that are new or have a new note since the last round, counted against `MAX_REVIEW_ROUNDS`. Fetching the same threads again is the same round. Threads you answered last are left out until someone writes after you. Only `duo-round-lib.sh` knows its formats: `review.json`, the seen set in task state, and `review-triage.md`.
_Avoid_: review cycle, iteration

**Triage**:
The review-responder's verdict on each thread of a Duo round, FIX, PUSH BACK or ASK, written to `review-triage.md` from the template in its instructions. The router reads the round, whether replies were posted, and the ASK threads from it.
_Avoid_: classification, sorting

**Forge**:
The code host the pipeline asks about merge requests and their threads: GitLab, through `glab`. Only `forge-lib.sh` talks to it; scripts get plain facts from it (an MR's state, author, branches; whether it can be reviewed or adopted) and word their own refusals. ADR 0002 names this seam and builds no second forge.
_Avoid_: GitLab client, glab wrapper

**Review worktree**:
The separate git worktree an MR review checks the MR's head out into, so the user's own branch and uncommitted work are never touched. Agents may read it but not change it.
_Avoid_: review checkout, sandbox

**Finding**:
One numbered item (`CR-<n>`) in a task's `code-review.md`: a problem the reviewer found, with the user's Decision on it and the pipeline's bookkeeping lines (Route, Thread, Status, Replied). Both routes have them; only `findings-lib.sh` reads or changes them.
_Avoid_: comment, issue, note

**Manual mode**:
Running a task by picking each stage agent yourself and following its **Next:** line, instead of an auto run. It is the fallback when an auto run can't be used.
_Avoid_: stage-by-stage mode, step mode

### Guard

**Protected path**:
A file or folder that belongs to the user or to the pipeline's own scripts, which agents may not change (and, for secrets, may not read).
_Avoid_: locked file, guarded path

### Installing

**Pipeline file**:
A file the installer owns in the user's project, such as an agent, skill, hook or pipeline script; an update replaces it unless the user changed it. Many pipeline files are protected paths, but not all (the guide isn't), and not every protected path is a pipeline file (secrets, `.agent.env`).
_Avoid_: managed file, installed file
