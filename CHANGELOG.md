# Changelog

## v1.0.0

First release.

- **Agents:** requirements, planner, implementer, verifier, reviewer, evidence, shipper, review-responder, each with a pinned model.
- **Integrations:** ClickUp via its REST API (`clickup.sh`), with no MCP needed; GitLab MRs and GitLab Duo review loop via `glab`.
- **Your checkpoints:** screenshot evidence with a user-only approval gate (SHA-256 fingerprints); code review with fix routing (quick, re-plan or requirements) and local-only tech debt.
- **Hooks:** a pre-tool guard (asks before anything publishes; blocks secrets, destructive git, raw pushes and test commands, and pipeline edits) and a post-edit formatter.
- **Installer:** install, update (keeps your changes), force, uninstall.
