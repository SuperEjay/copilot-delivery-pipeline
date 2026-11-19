# Copilot delivery pipeline

Turn a ClickUp task into a reviewed GitLab merge request with GitHub Copilot in
VS Code. You install it into your own project. It adds a set of Copilot agents,
each doing one step of delivery, and scripts and hooks that keep them inside
safe limits. You stay in charge of every decision that matters.

## What it does

Pick the **pipeline** agent, give it a ClickUp task id with
`/start-task <id> <slug>`, and it runs each stage for you as an **auto run**,
stopping only where a decision is yours:

1. **Read the task** (description, comments, attachments, linked docs) and write
   the requirements, with open questions for you to answer.
2. **Plan** the work in small slices, listing the files each one touches.
3. **Build** one slice at a time, then **verify** it with your project's own
   lint, type check and tests.
4. **Review** the code in depth. For each finding you decide: fix it, park it as
   tech debt (kept on your machine) or skip it.
5. **Capture evidence:** a screenshot (or a short note) for each acceptance
   criterion, which you check and approve.
6. **Ship:** push the verified commit, open the MR, and attach the approved
   evidence to the ClickUp task.
7. **Answer GitLab Duo's review:** triage its comments, fix, re-verify, push and
   reply.

It never merges the MR: that stays with you and your team. When an auto run
can't be used (say, a VS Code update breaks subagents), fall back to
manual mode: pick each stage agent yourself, following the **Next:** line at
the end of its reply. Everything runs in your VS Code, using your
Copilot plan and your own ClickUp and GitLab accounts. There's no server to host.

## Why use it

- **Auto run:** the `pipeline` agent runs the stages for you as subagents,
  stopping only where a decision is yours (requirements, a risky plan, unclear
  review findings, before the push). Never with **Auto** in the model picker: it
  cancels the pinned models. See
  [Daily use: auto run](payload/docs/agent-pipeline.md#daily-use-auto-run).
- **No MCP needed:** ClickUp goes through its REST API, GitLab through `glab`.
- **Enforced rules:** a hook guards every agent tool call. Publishing needs your
  confirmation; secrets, destructive git, raw pushes and edits to the pipeline
  itself are blocked.
- **Token-conscious:** condensed test output, a file-based handoff between
  stages, re-reviews of new commits only, a model pinned per agent, and optional
  ponytail and caveman skills.
- **Tech debt stays local:** the reviewer parks it in `.work/<task>/tech-debt.md`
  for you to decide on. Nothing is sent anywhere unless you choose to.

New here? Start with [Requirements](#requirements), then
[First-time install](#first-time-install). Already installed? See
[Updating an existing install](#updating-an-existing-install). The full guide
(setup, the auto run, manual mode, models, hooks, evidence approval, code review) is installed
into your project as [`docs/agent-pipeline.md`](payload/docs/agent-pipeline.md).

## Requirements

| What | Why |
|---|---|
| VS Code 1.106+ with GitHub Copilot | Runs the agents, skills and hooks. Hooks are a preview feature, and your organization may restrict them. |
| `bash` | Every pipeline script. macOS's own bash 3.2 is enough. |
| `git` | Branches, commits and the ship gate |
| `glab`, logged in to your GitLab | MRs and the GitLab Duo review loop |
| `jq` | The hook guard (on every agent tool call), ClickUp and GitLab data |
| `curl` | The ClickUp API, and the one-line install |
| Node.js (current LTS) with `npx` | Playwright screenshots for evidence, and the optional skills |
| Optional: `pdftotext` (Poppler) and `pandoc` | ClickUp PDF and Word attachments saved as text the agents can read |
| Optional: `jscpd` in your project | Duplication signals for the reviewer |

You also need a GitLab project and a ClickUp account that can create a
personal API token.

**Windows and line endings:** Git for Windows can check out `.sh` files with
CRLF line endings (`core.autocrlf=true`), and bash then fails with
`$'\r': command not found`. Before you commit the pipeline files, add this line
to your project's `.gitattributes` so every teammate gets LF:

```
*.sh text eol=lf
```

## Install the dependencies

Pick your platform. Each one ends with the same check.

### macOS

1. Install [Homebrew](https://brew.sh) if you don't have it.
2. Install the tools. `git` and `curl` come with the Xcode command line tools.

   ```bash
   xcode-select --install
   brew install jq glab node
   brew install poppler pandoc   # optional
   ```

### Linux

Install `git`, `curl`, `jq`, `glab` and Node.js with your package manager:

- **Debian, Ubuntu:**

  ```bash
  sudo apt update
  sudo apt install git curl jq
  sudo apt install poppler-utils pandoc   # optional
  ```

  `glab` has no official apt package: install it with
  [Homebrew on Linux](https://brew.sh) (`brew install glab`) or another option from
  [glab's install page](https://gitlab.com/gitlab-org/cli/-/blob/main/docs/installation_options.md).
  Distribution `node` packages are often old: install the current LTS from
  [nodejs.org](https://nodejs.org) or with `nvm`.
- **Fedora:** `sudo dnf install git curl jq glab nodejs poppler-utils pandoc`
- **Arch:** `sudo pacman -S git curl jq glab nodejs npm poppler pandoc`

Playwright's browsers need system libraries on Linux. When you set up evidence,
use `npx playwright install --with-deps chromium`.

### Windows with WSL

The supported way on Windows, and the setup the auto run was tested on: VS
Code runs on Windows, and everything else (Copilot's agents, the hooks, the
terminal) runs inside Linux.

1. In PowerShell as administrator, run `wsl --install`, then restart. You get
   Ubuntu.
2. Install [VS Code](https://code.visualstudio.com) on Windows, and its **WSL**
   extension (`ms-vscode-remote.remote-wsl`).
3. In the Ubuntu terminal, install the tools as for Debian/Ubuntu under
   [Linux](#linux): `git`, `curl`, `jq`, `glab` and `node`.
4. Keep your project in the Linux file system (for example `~/projects/app`),
   not under `/mnt/c/`. It's much faster, and Windows Git never touches its line
   endings. Clone it there with the Linux `git`.
5. Open it from the Ubuntu terminal with `code .`. The status bar shows
   **WSL: Ubuntu**. Do every step below in that window's terminal.

### Windows with Git Bash

**Unsupported:** nobody has run the pipeline this way, and it isn't tested. Use
[WSL](#windows-with-wsl). The hook file (`.github/hooks/pipeline-guard.json`)
has only a `bash` command, and it isn't known whether VS Code on Windows runs
it. If it doesn't, the guard is off and nothing stops an agent from pushing or
reading secrets. `scripts/agent/doctor.sh` fails on Git Bash for this reason. The notes below are kept for anyone who tries it anyway.

1. In PowerShell, install the tools: `git`, `jq`, `glab` and Node.js (`node`).
   Git for Windows also brings Git Bash and `curl`.

   ```powershell
   winget install --id Git.Git -e
   winget install jqlang.jq
   winget install glab.glab
   winget install OpenJS.NodeJS.LTS
   winget install JohnMacFarlane.Pandoc   # optional
   ```

2. In VS Code, make Git Bash the default terminal: Command Palette →
   **Terminal: Select Default Profile** → **Git Bash**. The agents run the
   pipeline's scripts in that terminal.
3. Open a new Git Bash terminal, so it sees the tools you just installed.
4. Add the `.gitattributes` line from [Requirements](#requirements) to your project.

### Check the tools

In the terminal you'll use (Git Bash, or the WSL terminal on Windows):

```bash
git --version; curl --version | head -n1; jq --version; glab --version; node --version
```

Each prints a version. Then log in to GitLab with `glab auth login`. For a
self-managed GitLab, add `--hostname gitlab.example.com`.

## First-time install

1. Open a terminal at your project's root (a git repository). Start from a
   clean tree, on a new branch:

   ```bash
   git status
   git switch -c chore/agent-pipeline
   ```

2. Run the installer. Either option installs the same files.

   ```bash
   # Option A: clone, read, run (recommended)
   git clone -c core.autocrlf=false --branch v1.2.2 https://github.com/SuperEjay/copilot-delivery-pipeline.git /tmp/cdp
   /tmp/cdp/install.sh .

   # Option B: one line, pinned to a release
   curl -fsSL https://raw.githubusercontent.com/SuperEjay/copilot-delivery-pipeline/v1.2.2/install.sh | bash
   ```

3. Read the installer's output. It ends by running `scripts/agent/doctor.sh`,
   which prints one line per check: PASS, WARN, FAIL or INFO. The guard's line
   should read `PASS  hook guard works (a test 'git push' was blocked)`. A FAIL
   for the token or `.agent.env` is expected now: the next step fixes it. Run
   `scripts/agent/doctor.sh` again after setup, until it shows no FAIL.
4. Configure the pipeline, following steps 4 to 10 of the guide's
   [Setup](payload/docs/agent-pipeline.md#setup-about-15-minutes):
   - your test commands in `.agent.env` (the installer created it)
   - `export CLICKUP_API_TOKEN="pk_..."` in your shell profile (`~/.zshrc` on
     macOS, `~/.bashrc` on Linux, WSL and Git Bash), never in the repo
   - `CLICKUP_TEAM_ID` and `DUO_USERNAMES` in `.agent.env`
   - Playwright and the evidence settings, for screenshots
5. Check that the model names in `.github/agents/*.agent.md` match your Copilot
   model picker. See
   [Models](payload/docs/agent-pipeline.md#models-pinned-per-agent).
6. Commit the pipeline files, so your teammates get the same agents and hooks.
   `.agent.env` is gitignored and stays on your machine.

   ```bash
   git add .github scripts/agent docs/agent-pipeline.md .agent.env.example .gitignore .gitattributes
   git commit -m "Add the agent pipeline"
   ```

   Leave `.gitattributes` out if you didn't create one.
7. Fully quit and reopen VS Code, then check:
   - the agents (requirements … review-responder, and **pipeline**) are in the
     Copilot Chat agent picker
   - `/start-task` and `/fetch-review` appear when you type `/`
   - asking any agent to run `git push` is refused, with the guard's reason
8. Pick **pipeline** and start your first task with
   `/start-task <clickup-id> <short-slug>`: see
   [Daily use: auto run](payload/docs/agent-pipeline.md#daily-use-auto-run). To
   go stage by stage instead, pick **requirements** first: see
   [Manual mode](payload/docs/agent-pipeline.md#manual-mode-fallback).

## Updating an existing install

1. See which version you have:

   ```bash
   head -n1 .github/agent-pipeline.manifest
   ```

   It prints `# agent-pipeline <version> installed <date>`. Compare it with the
   [latest release](https://github.com/SuperEjay/copilot-delivery-pipeline/releases/latest).
2. Start from a clean tree, on a new branch, and finish or park any task that's
   mid-stage if the CHANGELOG asks you to (step 5).

   ```bash
   git status
   git switch -c chore/agent-pipeline-update
   ```

3. Run the new version's installer with `--update`:

   ```bash
   # Option A: from a clone (clone it again as in First-time install if /tmp/cdp is gone)
   git -C /tmp/cdp fetch --tags && git -C /tmp/cdp checkout v1.2.2
   /tmp/cdp/install.sh --update .

   # Option B: one line
   curl -fsSL https://raw.githubusercontent.com/SuperEjay/copilot-delivery-pipeline/v1.2.2/install.sh | bash -s -- --update
   ```

4. Merge each `.new` file. When you'd changed a pipeline file, the installer
   keeps yours and writes the new version next to it as `<file>.new`, and says
   so in its output. To list them:

   ```bash
   find . -name '*.new' -not -path './node_modules/*'
   ```

   Merge each one into your file, then delete the `.new`. Or take every new
   version with `install.sh --update --force` (yours are saved as `.bak`). An
   auto run won't start while an agent file lacks the new version's sections.
5. Follow the upgrade steps in the [CHANGELOG](CHANGELOG.md) for every version
   after the one you had, oldest first. For example, from v1.1.0, see
   [Upgrading from v1.1.0](CHANGELOG.md#upgrading-from-v110).
6. If the output lists settings your `.agent.env` doesn't set, copy the ones you
   want from `.agent.env.example`. The installer never writes `.agent.env`.
7. Check the `doctor.sh` lines at the end of the output: fix any FAIL, then run
   `scripts/agent/doctor.sh` until there's none. Commit the updated pipeline
   files (the same `git add` as in First-time install), and fully quit and
   reopen VS Code.

## Installer options

| Command | What it does |
|---|---|
| `install.sh [dir]` | Install into a project |
| `install.sh --update [dir]` | Update to this version. Files you changed are kept, with the new version next to each as `<file>.new` to merge. |
| `install.sh --update --force [dir]` | Update and replace changed files (your versions saved as `.bak`) |
| `install.sh --uninstall [dir]` | Remove the pipeline. Keeps `.agent.env` and `.work/`. |
| `install.sh --with-skills` | Also install the ponytail and caveman skills for Copilot |
| `install.sh --yes` | No questions asked |
| `install.sh --version <tag>` | When run through curl: download that release instead of the script's own |

Through curl, pass options after `bash -s --`, for example
`curl -fsSL <install.sh URL> | bash -s -- --update`.

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

## Development

```bash
tests/test-install.sh     # installs into a scratch repo, then updates, forces and uninstalls
tests/test-guard.sh       # checks the hook guard's allow / deny / ask decision for each tool call
tests/test-gates.sh       # checks that only the verified commit can be pushed (stub glab, local remote)
tests/test-task-state.sh  # checks that .work/<id>/state.env is read as data and written in one format
tests/test-next-stage.sh  # checks the auto run's router: the next stage or stop for fixture .work/ folders
tests/test-agents.sh      # checks the stage agents: subagent frontmatter, no handoffs, the "In an auto run" sections
tests/test-orchestrator.sh  # checks the orchestrator (pipeline agent) against the router's verbs and stop ids
tests/test-doctor.sh      # checks doctor.sh: each PASS, WARN and FAIL, with fake tools on PATH, and that it changes nothing
```

The pipeline itself lives in `payload/`. Bump `VERSION`, tag a release
(`git tag v1.x.y`), and push the tag so the curl install can find it.
