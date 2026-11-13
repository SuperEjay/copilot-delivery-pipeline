# Copilot delivery pipeline

A ClickUp → GitLab delivery pipeline built from GitHub Copilot custom agents in
VS Code. Eight agents take a task from requirements to a merged MR, with you
approving at each checkpoint:

```
/start-task → requirements → (you) → planner → (you) → implementer → verifier
→ reviewer → (you: fix / debt / skip) → evidence → (you: approve screenshots)
→ shipper → GitLab Duo → review-responder → (you) → …
```

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
curl -fsSL https://raw.githubusercontent.com/SuperEjay/copilot-delivery-pipeline/v1.1.0/install.sh | bash
```

Then follow the "Next steps" the installer prints: fill in `.agent.env`, export
`CLICKUP_API_TOKEN`, run `glab auth login`, and check the model names.

| Command | What it does |
|---|---|
| `install.sh [dir]` | Install into a project |
| `install.sh --update [dir]` | Update to this version. Files you changed are kept and reported. |
| `install.sh --update --force [dir]` | Update and replace changed files (your versions saved as `.bak`) |
| `install.sh --uninstall [dir]` | Remove the pipeline. Keeps `.agent.env` and `.work/`. |
| `install.sh --with-skills` | Also install the ponytail and caveman skills for Copilot |
| `install.sh --yes` | No questions asked |

**What the installer touches:**
- **Pipeline files** (listed with fingerprints in `.github/agent-pipeline.manifest`):
  - `.github/agents/`, `.github/skills/`, `.github/hooks/`
  - `scripts/agent/`
  - `docs/agent-pipeline.md`, `.agent.env.example`
- **Your existing files:** it never overwrites them. Rules go into
  `.github/copilot-instructions.md` and ignores into `.gitignore`, each inside
  `BEGIN/END agent-pipeline` markers. `.agent.env` is created only if missing.

## Requirements

- VS Code 1.106+ with GitHub Copilot. Hooks are a preview feature and your
  organization may restrict them.
- `git`, `glab` (logged in), `jq`, `curl`, and Node with Playwright (for screenshot evidence)
- Optional: `pdftotext` and `pandoc` (read ClickUp attachments), `jscpd` (duplication signals)
- macOS, Linux, or Windows via Git Bash or WSL

## Development

```bash
tests/test-install.sh     # installs into a scratch repo, then updates, forces and uninstalls
```

The pipeline itself lives in `payload/`. Bump `VERSION`, tag a release
(`git tag v1.x.y`), and push the tag so the curl install can find it.
