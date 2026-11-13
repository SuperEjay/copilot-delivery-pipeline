---
agent: requirements
description: "Start a ClickUp task: create the branch and work folder, then analyse the requirements"
argument-hint: "<clickup-task-id> <short-slug>"
---
Start task ${input:taskId:ClickUp task id, e.g. 86c1abcde} with slug ${input:slug:short-kebab-slug}.
Run `scripts/agent/start-task.sh` with those two values, then do your normal requirements steps.
