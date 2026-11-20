# Copilot delivery pipeline

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
The scripts' record of a task in `.work/<id>/state.env`: its branch, merge request and Duo review round. Scripts read and write it only through `task-state.sh`; it is data, never run as code.
_Avoid_: state file, task env

**Run log**:
The router's record of an auto run in `.work/<id>/run.log`: one line for each decision it prints and each approval it records, only ever appended. Only the router writes it; it is not one of the inputs that tell a stalled stage.
_Avoid_: history, audit log, trace

**MR review**:
The pipeline's second route: a read-only review of an existing merge request, usually a teammate's, against its spec, started with `/review-mr <iid>`. It finds bugs, technical debt and improvements, and posts only the findings the user picks. It never changes the MR's code.
_Avoid_: verifier, MR verification, PR review

**Review worktree**:
The separate git worktree an MR review checks the MR's head out into, so the user's own branch and uncommitted work are never touched. Agents may read it but not change it.
_Avoid_: review checkout, sandbox

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
