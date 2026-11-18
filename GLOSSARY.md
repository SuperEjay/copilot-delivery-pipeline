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
The agent that drives an auto run. It starts each stage agent, keeps the run's status, and is the only agent that talks to the user during the run.
_Avoid_: coordinator, conductor, main agent

**Stop**:
A point in an auto run where the pipeline waits for a human decision. Only an explicit approval moves the run on.
_Avoid_: checkpoint, pause, gate (a gate is enforced by scripts; see Ship gate)

**Auto-decision**:
A decision the pipeline made on the user's behalf during an auto run under a rule the user agreed to, recorded so the user can review it before shipping.
_Avoid_: default, implicit approval
