# Changelog

## v1.1.0

Works with Copilot (Agent Host) sessions, the default in current VS Code.

- `/start-task` and `/fetch-review` are now **agent skills** (`.github/skills/`) instead of prompt files, which Agent Host sessions don't load. `--update` removes the old prompt files.
- Every agent ends its reply with a **Next:** line naming the next agent to pick and what to say, because Agent Host sessions don't show handoff buttons. The buttons stay for Local-harness sessions.
- The requirements agent can start from just a task id (`Analyse <id>`) and make the slug itself.
- The hook guard also protects the pipeline's own skills from agent edits.

## v1.0.0

First release.

- **Agents:** requirements, planner, implementer, verifier, reviewer, evidence, shipper, review-responder, each with a pinned model.
- **Integrations:** ClickUp via its REST API (`clickup.sh`), with no MCP needed; GitLab MRs and GitLab Duo review loop via `glab`.
- **Your checkpoints:** screenshot evidence with a user-only approval gate (SHA-256 fingerprints); code review with fix routing (quick, re-plan or requirements) and local-only tech debt.
- **Hooks:** a pre-tool guard (asks before anything publishes; blocks secrets, destructive git, raw pushes and test commands, and pipeline edits) and a post-edit formatter.
- **Installer:** install, update (keeps your changes), force, uninstall.
