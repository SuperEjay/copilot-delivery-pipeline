# Changelog

## Unreleased

- The hook guard now blocks agents from changing pipeline config through the shell too (redirects, `sed -i`, `cp`, `mv`, `rm`, `chmod`, `tee`, inline `python -c` and similar), not only through edit tools. Before this, a shell command could rewrite or switch off the guard itself.
- New `tests/test-guard.sh`: a table of tool calls and the decision the guard must make for each.
- **Only verified code is pushed.** `run-checks.sh <id> all` records the commit it passed on a clean tree in `.work/<id>/verified-head`, and `create-mr.sh` and `push-branch.sh` refuse to push anything else. Before this, the shipper only checked that `verification.md` said PASS, so a commit added after verification could ship unverified.
- **Evidence is tied to a commit.** `approve-evidence.sh` records the full commit, and `upload-evidence.sh` (and so a new MR) refuses if HEAD has moved on since. Existing approvals with a short sha still work.
- **Duo fixes are verified before they're pushed.** The review-responder commits fixes and hands over to the verifier; it pushes and replies on the threads only after the verifier passes (`Push and reply <id>`).
- **Re-fetching a Duo review doesn't use up a round.** `fetch-duo-review.sh` counts a new round only when the set of threads changes.
- The verifier now commits its new tests first and runs `run-checks.sh all` last.
- New `tests/test-gates.sh` covers the push gates and round counting.
- The ship gate's rules (right branch, verified commit, evidence approved at that commit) now live in one module, `scripts/agent/ship-gate.sh`, and the evidence approval record is written and checked only in `evidence-lib.sh`. No behaviour change: `create-mr.sh` and `push-branch.sh` call the gate, `run-checks.sh` records verification through it, and `tests/test-gates.sh` tests the rules against the gate directly.

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
