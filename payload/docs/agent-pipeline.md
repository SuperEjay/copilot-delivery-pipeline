# ClickUp → GitLab agent pipeline (GitHub Copilot custom agents)

```
/start-task ─► requirements ─(you approve)─► planner ─(you approve)─► implementer ×N slices
                  ▲                             ▲                            │
                  │ route: requirements         │ route: re-plan             ▼
                  └──────────────┬──────────────┘                         verifier
                                 │        route: quick ─► implementer        │ PASS
                                 │                                           ▼
                                 └──── (you decide per finding) ◄──── reviewer ──► tech-debt.md
                                                                             │       (local only)
                                                                             │ READY
                                                                             ▼
                                                       evidence ─► (YOU approve-evidence.sh)
                                                                             ▼
             review-responder ◄─(Duo reviews)◄─ shipper ─► MR + approved evidence to ClickUp
                 │  (you approve triage)            ▲
                 └──────────── fixes ───────────────┘ (via verifier)
```

Each stage writes one file into `.work/<task-id>/`, and the next stage reads it.
Your approval points are the handoff buttons, which have `send: false`, so you
can edit the prompt before the next agent starts.

## What's in here

| Path | What it is |
|---|---|
| `.github/agents/*.agent.md` | The eight agents: requirements, planner, implementer, verifier, reviewer, evidence, shipper, review-responder |
| `.github/prompts/start-task.prompt.md` | `/start-task <id> <slug>` |
| `.github/prompts/fetch-review.prompt.md` | `/fetch-review <id>` |
| `.github/hooks/pipeline-guard.json` | Hooks: a guard before every agent tool call, and a formatter after each edit |
| `.github/copilot-instructions.md` | Six short rules every agent follows (kept short on purpose: it's sent with every request) |
| `scripts/agent/` | Deterministic steps: branch/folder setup, ClickUp fetch/comment/status/attach, condensed test runner, review signals, evidence capture/approve/upload, MR create/update, Duo fetch, thread reply/resolve |
| `.agent.env.example` | Your test commands, Duo username, round limit, ClickUp workspace and status |

**No MCP needed.** ClickUp goes through its REST API (`scripts/agent/clickup.sh`)
and GitLab through `glab`. The agents only run scripts in the terminal, so an
admin policy that blocks MCP servers doesn't affect any of this.

## Setup (about 15 minutes)

1. **Install** (from your project's root): run the installer from the pipeline
   repo. It copies the files, makes the scripts executable, merges the rules into
   `.github/copilot-instructions.md`, adds `.work/`, `.agent.env`, `.auth/` and
   `*.bak` to `.gitignore`, and creates `.agent.env`. Update later with
   `install.sh --update`; remove with `install.sh --uninstall`.
2. **Commit the pipeline files** so your teammates get the same agents and hooks.
3. **Don't edit pipeline files casually.** `--update` keeps files you changed,
   but you'll miss improvements to them. Put project-specific settings in
   `.agent.env` instead.
4. **Configure:** open `.agent.env` (the installer created it) and set your real lint,
   typecheck, unit, integration and e2e commands. Leave a command empty to skip it.
5. **Install and log in to the CLIs:** `glab auth login` (point it at your GitLab
   host if it's self-managed), `jq` and `curl`. Optional: `pdftotext` (poppler)
   and `pandoc`, so PDF and Word attachments are also saved as text the agents
   can read.
6. **Connect ClickUp with a personal API token:**
   - In ClickUp: avatar → **Settings → Apps → API Token → Generate**. You get a
     token starting with `pk_`. It has the same access as your account.
   - Add it to your shell profile (`~/.zshrc` or `~/.bashrc`), **not** to the repo:
     `export CLICKUP_API_TOKEN="pk_..."`, then restart VS Code so its terminal
     picks it up. The script only sends it in a request header and never prints it.
   - Set `CLICKUP_TEAM_ID` in `.agent.env`: the first number in any ClickUp URL.
   - Test it: `scripts/agent/start-task.sh <task-id> test && scripts/agent/clickup.sh fetch <task-id>`,
     then open `.work/<task-id>/clickup/task.md`.
   - Personal API tokens are a separate setting from Copilot's MCP policy, but
     check your company allows them. If not, paste the task into the chat:
     the requirements agent works from a paste too.
7. **Find Duo's username:** open any MR Duo has reviewed, check the author name
   on its comment, and put it in `DUO_USERNAMES`.
8. **VS Code 1.106 or newer** is needed for the handoff buttons. Reload the
   window, and the agents appear in the Copilot Chat agent picker.
9. **Evidence screenshots (Playwright):**
   - If the repo doesn't have it yet: `npm i -D @playwright/test && npx playwright install chromium`.
   - Set `EVIDENCE_BASE_URL` and `EVIDENCE_START_CMD` in `.agent.env`.
   - If pages need a login, save a **test account's** session once:
     `npx playwright codegen --save-storage=.auth/evidence.json <your app URL>`,
     log in, close the window, and set `EVIDENCE_STORAGE_STATE`. Re-run it when the
     session expires.

### Models (pinned per agent)
Each agent file has a `model:` line, using only the models your admins allow:

| Agent | Model | Why |
|---|---|---|
| requirements | Claude Opus 5.5 | Misreading the ticket is the costliest mistake; runs are short |
| planner | Claude Opus 5.5 | Slicing and design shape everything after |
| implementer | Claude Sonnet 5.5 | Most tokens are spent here; solid feature work at mid price |
| verifier | GPT-6 Sol | A different family from the implementer grades more independently |
| reviewer | GPT-6 Sol | Different blind spots from the model that wrote the code |
| evidence | Claude Sonnet 5.5 | Playwright specs and screenshot checks: reliable, not deep |
| shipper | GPT-6 Luna | Mostly mechanical; the cheapest model |
| review-responder | Grok 4.7 | Triage and small fixes, cheap output. Trial it here before considering it for the implementer |

**Check the names once.** `model:` must match the name in your Copilot model
picker exactly. If a name differs (say `Claude Opus 5.5` vs `Opus 5.5`), fix
it in the agent file. Otherwise the agent may fall back to whatever model is
selected in the picker.

**No fast or priority modes.** Never pick a "fast mode", "priority" or other
premium-speed variant of a model. Fast variants cost several times more than
the standard model for the same work. The pinned names above are all standard
variants. Leave them that way.

## Daily use

1. `/start-task 86c1abcde invoice-export` → read `requirements.md`, answer the
   open questions in chat → **Approved → plan the slices**
2. Read `plan.md` → **Plan approved → build slice 1** → **Next slice** … →
   **All slices done → verify**
3. Verifier: FAIL goes back to the implementer, PASS goes to the **reviewer**.
4. **Your review decisions** (see "Code review and tech debt" below). Fixes
   loop back through the right stage; once the verdict is READY,
   **Review done → capture evidence**.
5. **Your evidence review** (see "Evidence approval" below), then
   **Evidence approved → prepare the MR**.
6. The shipper checks your approval, asks before pushing, opens the MR, uploads
   the approved evidence to ClickUp and comments with the MR link.
7. When Duo has reviewed: `/fetch-review 86c1abcde` → approve the triage table →
   fixes are pushed and threads replied to → **Re-verify after fixes**.
   After `MAX_REVIEW_ROUNDS` rounds, the fetch script stops and leaves the rest to you.

**Start a new chat for each stage** (the handoff button does this). The files
carry the context, so each agent starts small instead of dragging the whole
history along.

## Hooks (enforced rules)

`.github/hooks/pipeline-guard.json` runs `scripts/agent/hooks/pre-tool-guard.sh`
before **every** agent tool call. It turns the pipeline's rules from
instructions into enforcement:

| Decision | What |
|---|---|
| **Ask you** | Anything that publishes: `create-mr.sh`, `push-branch.sh`, `upload-evidence.sh`, and `clickup.sh comment / status / attach`. VS Code shows a confirm prompt, which is your final go-ahead. |
| **Deny** | Running `approve-evidence.sh`, or touching `evidence/APPROVED` or `evidence/UPLOADED` |
| **Deny** | Reading or printing secrets: token variables, `printenv`/`env`, `.auth/` sessions, `~/.ssh`, `.netrc`, `.npmrc`, literal `pk_`/`glpat-` tokens |
| **Deny** | Destructive git: force push, remote branch delete, `reset --hard`, `clean -f`, `branch -D`, `checkout -- .`, `--no-verify` |
| **Deny** | Raw `git push`, `glab` write commands, or direct ClickUp API calls (the scripts must be used) |
| **Deny** | Raw test, lint and typecheck commands (`npm test`, `npx vitest`, `npx playwright test`, `npx tsc`…), so output always goes through the condensed `run-checks.sh` |
| **Deny** | Agent edits to pipeline config: agent files (including their pinned models), hooks, prompts, `copilot-instructions.md`, `scripts/agent/`, `.agent.env` |

The agent sees the reason and adjusts. Every ask or deny is logged to
`.work/hooks.log`, so you can see what was blocked. **You** can still edit all
of these files by hand. The guard only applies to agent tool calls.

The second hook, `post-edit-format.sh`, runs `FORMAT_CMD` from `.agent.env`
(e.g. `npx prettier --write`) on every file an agent edits. It's off while
`FORMAT_CMD` is empty.

**Good to know:**
- **Hooks are in preview** in VS Code, and your organization can restrict which
  hooks run. After setup, check they're active: ask any agent to run
  `git push`. It should be refused with the guard's reason.
- **If the guard script errors, the call is denied, not allowed** (Copilot's
  rule for `preToolUse`). A guard that can't run (missing `jq`, say) blocks
  agent tool calls until it's fixed. **Timeouts do let calls through**, so the
  guard is kept fast: about 30 ms per call.
- **Emergency off switch:** start VS Code with `PIPELINE_GUARD=off` in its
  environment. Agents can't set this; it has to come from your shell.
- **Fast and priority modes can't be blocked by a hook** (hooks see tool calls,
  not which model is running). Pinned models plus the guard on agent-file edits
  cover the pipeline. For the rest of Copilot, ask your admins to keep the
  fast-mode policies off. For Business and Enterprise they're off by default.

## Code review and tech debt (you decide)

After tests pass, the **reviewer** does a deep review before Duo or a teammate
sees the code. It covers correctness, error handling, async and concurrency,
security, performance, data and migrations, API contracts, test quality,
maintainability and debt, and observability.

It starts from `review-signals.sh`, a cheap report of mechanical leads: churn
per file, source changed without a matching test change, new TODOs, debug
output, focused or skipped tests, lint and type suppressions, possible secrets,
hard-coded URLs, swallowed errors, timing hacks, dependency changes and
migrations. Then it reads the diff file by file. Every finding in
`code-review.md` has a severity, a concrete failure scenario, a suggested fix,
an effort estimate and a recommendation. It also covers **pre-existing debt** in
the code the change touches.

**You decide per finding**: **fix**, **debt** or **skip**, or reply "accept recommendations".

**Where fixes restart.** The reviewer proposes a route for each fix and asks you
to confirm. It goes back only as far as the change needs:

| Route | When | Goes to |
|---|---|---|
| `quick` | Small (S), inside files the plan already touches, no behaviour change | implementer → verifier → delta review |
| `re-plan` | Bigger (M/L), new modules, interface or data changes, migrations | planner adds `R1, R2…` slices → build → verify → review |
| `requirements` | The right fix depends on behaviour the ticket doesn't define | requirements agent adds a question or AC → plan → … |

Done slices are never redone. Each re-review covers only the commits since
the last review, so later passes are cheap.

**Tech debt stays local.** Findings you mark **debt** go to
`.work/<id>/tech-debt.md` with `Status: parked`. They aren't sent to ClickUp,
GitLab or the MR. When you've decided:
- "pull CR-5 in": it gets a route and goes through the fix loop.
- "drop CR-5": it's marked dropped, with your reason.
- Anything you'd like tracked, you push to ClickUp yourself.

`.work/` is gitignored, so the file stays on your machine across sessions until
you delete it.

## Evidence approval (you, before shipping)

The evidence agent captures a screenshot for each UI acceptance criterion (or a
short text file for non-UI ones), then writes
`.work/<id>/evidence/evidence.md` with every item **unticked**.

1. Open `evidence.md` and press `Ctrl/Cmd+Shift+V` for the Markdown preview,
   which shows the screenshots inline.
2. In the file itself, tick `- [x]` on each item you approve. For anything you
   want redone, write a note under it and tell the evidence agent "retake AC-2".
3. In your own terminal, run `scripts/agent/approve-evidence.sh <id>`. It shows
   what will and won't be uploaded and asks you to type `approve`.
4. Click **Evidence approved → prepare the MR**.

How the gate holds:
- The approval stores a SHA-256 fingerprint of each approved file and of the manifest.
- The shipper runs `upload-evidence.sh --check` first and stops if there's no
  approval, or if anything changed after you approved it.
- Re-capturing evidence deletes the old approval.
- Only ticked items are uploaded. Unticked ones stay on your machine.
- Agents are told never to tick boxes or run the approve script, and the script
  refuses to run without a real terminal.

This is a guardrail against mistakes and drift, not a security boundary: an
agent with terminal access could in principle get around it. Keep an eye on
which commands you approve in the chat.

Screenshots go to your ClickUp task, so the agent masks personal data and uses
test accounts. Still check each one for customer data before you tick it.

## What `clickup.sh fetch` pulls

One file, `.work/<id>/clickup/task.md`, containing: title, status, priority,
due date, assignees and tags; the description (as Markdown); non-empty custom
fields; checklists; subtasks with their descriptions; attachments (downloaded,
with PDF and Word files converted to text when the tools are installed);
comments oldest first, with threaded replies; and linked ClickUp Docs saved as
Markdown under `clickup/docs/`. The raw JSON is kept alongside it as a backup,
but agents are told to read only `task.md`.

## Token savers already built in

- **One condensed `task.md` instead of raw API JSON.** The ClickUp API's JSON is
  several times larger than the information in it.

- **`run-checks.sh` condenses test output.** The agent sees one line per check
  plus the failing lines. The full logs go to `.work/<id>/logs/`. On a big test
  suite, this is the largest single saving.
- **Files are the handoff, not chat history**, and the instructions tell agents
  not to restate file contents.
- **`plan.md` lists exact file paths for each slice**, so the implementer doesn't
  search the repo again on every slice.
- **`review.json` holds only unresolved threads, trimmed**, and the round cap
  stops endless back-and-forth with Duo.
- **Narrow tool lists per agent.** Every enabled tool's definition is sent with
  each request, and fewer tools also means fewer wrong turns.
- **Short always-on instructions.** Detail lives in the agents and skills, which
  load only when used.

## Recommended skills

### From mattpocock-skills (you already have these), by stage
| Stage | Skill | Why |
|---|---|---|
| Requirements | `grill-me`, `to-spec` | Pull out unstated requirements before any code exists |
| Requirements | `domain-modeling` | Builds `CONTEXT.md`. Agents reuse your terms instead of rediscovering them every task, which saves tokens repeatedly |
| Plan | `to-tickets`, `codebase-design` | Tracer-bullet slices and clean module seams |
| Build | `tdd`, `implement` | Test-first, so the verifier mostly confirms instead of discovering |
| Build (stuck) | `diagnosing-bugs` | A structured loop instead of guess-and-retry, which burns tokens |
| Review | `code-review` | Standards + Spec review against a base branch; the reviewer agent merges its findings |
| Review | `codebase-design` | Shared vocabulary (deep modules, seams) for maintainability findings |
| Ship | `pr` | MR descriptions |
| Any long session | `handoff` | Compacts a long chat into a file so you can continue in a fresh, small session |
| After the task | `retro` | Turns what went wrong into fixes to these agent files |
| Once per repo | `setup-pre-commit` | Lint, typecheck and tests on commit: catches problems without spending any tokens |
| Every month or so | `improve-codebase-architecture` | Deeper modules make every later task cheaper for agents to understand |

`git-guardrails-claude-code` relies on Claude Code hooks, so it doesn't apply to
Copilot. The instruction "never push without a go-ahead" is the equivalent here.

### For saving tokens
- **ponytail** (adopted for implementer, evidence and review-responder):
  `npx skills add DietrichGebert/ponytail -g`. Makes the agent reuse existing
  code, the standard library and the platform before writing new code, while
  keeping validation and security. The agent files say how to apply it.
  Expect real but smaller savings than the README's own numbers.
- **caveman** (adopted in **lite** mode for chat replies from requirements and
  review-responder only; files stay in full sentences) (`npx skills add JuliusBrussee/caveman -a github-copilot`). Makes
  the agent's prose replies terse while keeping code, commands and errors exact.
  It cuts **output** tokens only, so it pays off in chatty stages (requirements
  Q&A, triage, review replies) and much less when the output is mostly code.
  Start with `lite` mode. Its `caveman-compress` command can shrink instruction
  files, but check the result by hand before committing it: agent instructions
  need to stay unambiguous.
- **`handoff` + new chat per stage** (above). Long sessions get expensive
  because the whole history is re-sent with every request.
- **`domain-modeling` / `CONTEXT.md`** (above). A shared glossary is cheaper
  than rediscovering terms on every task.

### For e2e testing
- **webapp-testing** from `anthropics/skills`: drives Playwright scripts to test
  a running web app. It's useful for the verifier when an AC needs a real
  browser flow. Prefer committed Playwright specs run through `run-checks.sh e2e`
  over driving a browser live with an MCP tool: live browser snapshots are very
  token-heavy.
