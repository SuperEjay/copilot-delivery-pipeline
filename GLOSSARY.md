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
