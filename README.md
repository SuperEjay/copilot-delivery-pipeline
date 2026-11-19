# Copilot delivery pipeline

A ClickUp → GitLab delivery pipeline built from GitHub Copilot custom agents in
VS Code. Eight agents take a task from requirements to a merged MR, with you
approving at each checkpoint:

```
/start-task → requirements → (you) → planner → (you) → implementer → verifier
→ reviewer → (you: fix / debt / skip) → evidence → (you: approve screenshots)
→ shipper → GitLab Duo → review-responder → (you) → …
```

- **Auto run:** pick the `pipeline` agent and it runs the stages for you as
  subagents, stopping only where a decision is yours (requirements, a risky plan,
  unclear review findings, before the push). Never with **Auto** in the model
  picker: it cancels the pinned models. See "Hands-off: auto run" in
  `payload/docs/agent-pipeline.md`.
- **No MCP needed:** ClickUp goes through its REST API, GitLab through `glab`.
- **Enforced rules:** a hook guards every agent tool call. Publishing needs your
  confirmation; secrets, destructive git, raw pushes and edits to the pipeline
  itself are blocked.
- **Token-conscious:** condensed test output, a file-based handoff between
  stages, re-reviews of new commits only, a model pinned per agent, and optional
  ponytail and caveman skills.
- **Tech debt stays local:** the reviewer parks it in `.work/<task>/tech-debt.md`
  for you to decide on. Nothing is sent anywhere unless you choose to.

The full guide (setup, daily use, models, hooks, evidence approval, code review)
is installed into your project as [`docs/agent-pipeline.md`](payload/docs/agent-pipeline.md).

## Install

From your project's root (a git repository):

```bash
# Option A: clone, read, run (recommended)
git clone https://github.com/SuperEjay/copilot-delivery-pipeline.git /tmp/cdp
/tmp/cdp/install.sh .

# Option B: one line, pinned to a release
curl -fsSL https://raw.githubusercontent.com/SuperEjay/copilot-delivery-pipeline/v1.2.0/install.sh | bash
```

Then follow the "Next steps" the installer prints: fill in `.agent.env`, export
`CLICKUP_API_TOKEN`, run `glab auth login`, and check the model names.

| Command | What it does |
|---|---|
| `install.sh [dir]` | Install into a project |
| `install.sh --update [dir]` | Update to this version. Files you changed are kept, with the new version next to each as `<file>.new` to merge. |
| `install.sh --update --force [dir]` | Update and replace changed files (your versions saved as `.bak`) |
| `install.sh --uninstall [dir]` | Remove the pipeline. Keeps `.agent.env` and `.work/`. |
| `install.sh --with-skills` | Also install the ponytail and caveman skills for Copilot |
| `install.sh --yes` | No questions asked |

**Upgrading from v1.1.0:**

1. Run `install.sh --update`.
2. Merge each `<file>.new` it reports into the file you changed (or re-run with `--force` to take the new version; yours is kept as `.bak`). An auto run needs every stage agent's `## In an auto run` section, and `next-stage.sh` names any agent file that lacks it.
3. Finish tasks you started before the update stage by stage. Their `plan.md` has no `## Stop flags`, so `next-stage.sh` won't run them.
4. Optional: add `MAX_AUTO_FIX_ROUNDS` (default 2) to `.agent.env`. `--update` lists every setting in `.agent.env.example` that your `.agent.env` doesn't set, and never writes the file.

**What the installer touches:**
- **Pipeline files** (listed with fingerprints in `.github/agent-pipeline.manifest`):
  - `.github/agents/`, `.github/skills/`, `.github/hooks/`
  - `scripts/agent/`
  - `docs/agent-pipeline.md`, `.agent.env.example`
- **Your existing files:** it never overwrites them. Rules go into
  `.github/copilot-instructions.md` and ignores into `.gitignore`, each inside
  `BEGIN/END agent-pipeline` markers. `--update` replaces everything between
  the markers, so put your own rules and ignores outside them. `.agent.env` is
  created only if missing.

## Requirements

- VS Code 1.106+ with GitHub Copilot. Hooks are a preview feature and your
  organization may restrict them.
- `git`, `glab` (logged in), `jq`, `curl`, and Node with Playwright (for screenshot evidence)
- Optional: `pdftotext` and `pandoc` (read ClickUp attachments), `jscpd` (duplication signals)
- macOS, Linux, or Windows via Git Bash or WSL

## Development

```bash
tests/test-install.sh     # installs into a scratch repo, then updates, forces and uninstalls
tests/test-guard.sh       # checks the hook guard's allow / deny / ask decision for each tool call
tests/test-gates.sh       # checks that only the verified commit can be pushed (stub glab, local remote)
tests/test-task-state.sh  # checks that .work/<id>/state.env is read as data and written in one format
tests/test-next-stage.sh  # checks the auto run's router: the next stage or stop for fixture .work/ folders
tests/test-agents.sh      # checks the stage agents: subagent frontmatter, handoffs, the "In an auto run" sections
tests/test-orchestrator.sh  # checks the orchestrator (pipeline agent) against the router's verbs and stop ids
```

The pipeline itself lives in `payload/`. Bump `VERSION`, tag a release
(`git tag v1.x.y`), and push the tag so the curl install can find it.
