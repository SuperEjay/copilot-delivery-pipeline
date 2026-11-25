# ClickUp → GitLab agent pipeline (GitHub Copilot custom agents)

```
Auto run: the pipeline agent runs each stage as a subagent, in the order
scripts/agent/next-stage.sh decides, and stops at ⏸. Manual mode: pick each agent
from its "Next:" line.

              /start-task <id> <slug>
                    │
                    ▼
              requirements ······················ ⏸ requirements: answer it, or approve
                    │
                    ▼
              planner ··························· ⏸ plan: a Stop flag, or over 6 slices
                    │
                    ▼
  ┌──────┬───► implementer (one slice per run)
  │      │          │
  │ fail │          ▼
  │      └──── verifier ── records verified-head
  │                 │ PASS
  │ quick fix       ▼
  └─────────── reviewer ························· ⏸ review: an unclear finding, or a fix
                    │ └─► tech-debt.md (local)       sent back to requirements or planner
                    ▼ settled
              evidence
                    │
                    ▼
              shipper: writes mr.md ············· ⏸ pre-ship: YOU tick evidence.md and run
                    │                               approve-evidence.sh
                    ▼
              shipper: ship gate, push, MR, approved evidence to ClickUp
                    │
                    ▼
              ■ end: MR open. After Duo reviews it: /fetch-review <id>
                    │
                    ▼
  ┌──────────► review-responder: triage, commit fixes
  │                 │
  │                 ▼
  │           verifier: re-verify
  │                 │
  │                 ▼
  │           review-responder: push, reply ····· ⏸ duo: ASK threads, or fixes to push
  │                 │
  │                 ▼
  └─────────── ■ end: round answered. After the next Duo review: /fetch-review <id>

MR review (ADR 0003): a read-only review of an existing MR, in a review worktree.

              /review-mr <iid> [clickup-id]
                    │
                    ▼
              requirements: the spec ············ ⏸ spec: no ClickUp task found
                    │
                    ▼  ·································· ⏸ focus: more than MR_REVIEW_MAX_FILES files
              verifier: checks (failures are findings)
                    │
                    ▼
              reviewer ·························· ⏸ findings: post, debt or skip each one
                    │
                    ▼
              reviewer: posts the ones marked post, each confirmed by you
                    │
                    ▼
              ■ end. After the author pushes: /review-mr <iid>

⏸ An auto run waits for your reply here; in manual mode, you decide as you go. Any stage can
  also stop: stalled (it changed nothing), fix-limit (MAX_AUTO_FIX_ROUNDS used).
```

**Only verified code is pushed.** When `run-checks.sh <id> all` passes on a
tree with no uncommitted changes, it records that commit in
`.work/<id>/verified-head`. `create-mr.sh` and `push-branch.sh` refuse to push
any other commit, so a commit added after verification can't slip out. A new
MR also needs the evidence approved at that same commit. All three rules (right
branch, verified commit, evidence approved at it) are the **ship gate**, in one
file: `scripts/agent/ship-gate.sh`.

Each stage writes one file into `.work/<task-id>/`, and the next stage reads it.
**Moving between stages:** in an auto run, the **pipeline** agent does it for
you (see "Daily use: auto run"). In manual mode, the fallback, every agent ends
its reply with a **Next:** line naming the agent to pick and what to say, e.g.
*"Next: pick the **planner** agent and say 'Plan 86c1abcde'"* (see "Manual mode
(fallback)").

## What's in here

| Path | What it is |
|---|---|
| `.github/agents/*.agent.md` | The eight stage agents (requirements, planner, implementer, verifier, reviewer, evidence, shipper, review-responder) and `pipeline`, the orchestrator of an auto run |
| `.github/skills/start-task/SKILL.md` | `/start-task <id> <slug>` (or `--mr <iid>` / `--branch <branch>` to adopt your own work): branch, work folder, ClickUp fetch, then on to requirements, or starts the auto run when **pipeline** is picked |
| `.github/skills/fetch-review/SKILL.md` | `/fetch-review <id> [--force]`: pull Duo's open threads, then on to review-responder, or resumes the auto run when **pipeline** is picked |
| `.github/skills/review-mr/SKILL.md` | `/review-mr <iid> [clickup-id]`: check out an existing MR for a read-only review and start its auto run when **pipeline** is picked; `/review-mr <iid> --done` cleans up (see "MR review (a teammate's MR)") |
| `.github/hooks/pipeline-guard.json` | Hooks: a guard before every agent tool call, and a formatter after each edit |
| `.github/copilot-instructions.md` | Six short rules every agent follows (kept short on purpose: it's sent with every request) |
| `scripts/agent/` | Deterministic steps: branch/folder setup, ClickUp fetch/comment/status/attach, condensed test runner, review signals, evidence capture/approve/upload, MR create/update, Duo fetch, applying a thread's suggestion block (`apply-suggestion.sh`), thread reply/resolve, MR review setup and posting (`start-review.sh`, `set-review-spec.sh`, `post-review-thread.sh`), `doctor.sh`, which checks your setup, and `stacks.sh`, its test tooling per stack |
| `.agent.env.example` | Your test commands, Duo username, round limit, ClickUp workspace and status, and the MR review settings |

**No MCP needed.** ClickUp goes through its REST API (`scripts/agent/clickup.sh`)
and GitLab through `glab`. The agents only run scripts in the terminal, so an
admin policy that blocks MCP servers doesn't affect any of this.

## Setup (about 15 minutes)

1. **Install** (from your project's root): run the installer from the pipeline
   repo. It copies the files, makes the scripts executable, merges the rules into
   `.github/copilot-instructions.md`, adds `.work/`, `.agent.env`, `.auth/`,
   `*.bak` and `*.new` to `.gitignore`, and creates `.agent.env`. Update later with
   `install.sh --update`; remove with `install.sh --uninstall`. The rules and
   ignores sit between `BEGIN/END agent-pipeline` markers, and `--update`
   replaces everything between them: put your own lines outside the markers.
2. **Commit the pipeline files** so your teammates get the same agents and hooks.
   Or, to keep the pipeline to yourself, install with `install.sh --local`: see
   "Keep the pipeline out of git" in the README.
3. **Don't edit pipeline files casually.** `--update` keeps files you changed
   and writes the new version next to each as `<file>.new`; until you merge it,
   you miss its improvements, and an auto run won't start with an old agent
   file. Put project-specific settings in `.agent.env` instead.
4. **Configure:** open `.agent.env` (the installer created it) and set your real lint,
   typecheck, unit, integration and e2e commands. Leave a command empty to skip it.
   e2e defaults to Playwright only when `package.json` has `@playwright/test`;
   without it, e2e is skipped (`SKIP` in `run-checks.sh`) and the verifier lists
   it under Gaps, so nothing blocks the push (ADR 0005). Set `E2E_CMD` to use
   another runner, or `E2E_CMD=` to always skip it.
   - **Which commands:** `doctor.sh` (step 8, and the end of the installer's
     output) prints a "test tooling" section for your project's stack: an
     `.agent.env` line per check, and the tool to install where one is missing.
     It covers **Node** (`package.json`) and **Laravel** (`composer.json` and
     `artisan`): Pest, else PHPUnit, for unit and integration (Pest
     recommended), Pint for lint, Larastan for types, and the Pest browser
     plugin for e2e, with Playwright as the alternative. It only advises:
     it never writes `.agent.env` or installs anything. A check whose
     `.agent.env` line differs from `.agent.env.example` shows your command
     instead. Another stack gets "set the commands in `.agent.env` by hand".
   - A Pest browser-test `E2E_CMD` is yours to set: only Playwright is found by
     itself, because Pest has no documented way to run only its browser tests.
     Without Playwright specs, evidence falls back to text (ADR 0005).
   - The stacks are one table in `scripts/agent/stacks.sh`; adding a stack is a
     row per check, described at the top of that file.
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
8. **Check the setup:** run `scripts/agent/doctor.sh`. It checks the tools,
   your `glab` login, that `CLICKUP_API_TOKEN` is exported (and in no file),
   settings `.agent.env` doesn't set, line endings, the hook guard and your VS
   Code version, one line each, then prints the test tooling for your stack
   (step 4), and changes nothing. Fix every FAIL. Run it again
   whenever something acts up, or when a teammate sets up.
9. **Fully quit and reopen VS Code.** The agents appear in the Copilot Chat
   agent picker, and `/start-task`, `/fetch-review` and `/review-mr` appear when you type `/`.
   They're agent skills, not prompt files, because prompt files only load in
   the Local harness; Copilot harness sessions, including Agent Host, use
   skills. If they're missing, check that VS Code is
   open on the project's root folder.
10. **Evidence screenshots (Playwright, optional):** without Playwright, e2e is
   skipped, UI ACs tested only below e2e pass with a gap, and screenshot ACs
   become text evidence. You can still add your own screenshots: see
   [Evidence approval](#evidence-approval-you-before-shipping).
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
| pipeline | GPT-6 Luna | The orchestrator only follows `next-stage.sh` and calls the stages; the cheapest model |
| gap-checker | Claude Sonnet 5.5 | Optional, picked by you at the pre-ship stop: walks the UI like the evidence agent checks screenshots |

**Check the names once.** `model:` must match the name in your Copilot model
picker exactly. If a name differs (say `Claude Opus 5.5` vs `Opus 5.5`), fix
it in the agent file. Otherwise the agent may fall back to whatever model is
selected in the picker.

**No fast or priority modes.** Never pick a "fast mode", "priority" or other
premium-speed variant of a model. Fast variants cost several times more than
the standard model for the same work. The pinned names above are all standard
variants. Leave them that way.

## Daily use: auto run

The way to run a task: the **pipeline** agent (the **orchestrator**) runs the
stages for you. It comes back to you only at a **stop**, where a decision is
yours. The design is in ADR 0001, and ADR 0002 makes it the main path. When an
auto run can't be used, see "Manual mode (fallback)" below.

**Don't use Auto in the model picker.** Under Auto, every stage runs on Auto's
choice and ignores its pinned model. The orchestrator warns about this once per
run, then goes on.

### Start

1. Pick **pipeline** in the agent picker, and a model other than Auto in the
   model picker if your plan offers one.
2. Run `/start-task 86c1abcde invoice-export`. The skill sets up the task, then
   hands over to the orchestrator. If a script fails (uncommitted changes, a
   ClickUp error), you get its message and the run doesn't start.
3. The orchestrator runs each stage agent as a subagent and prints one
   `▶ <agent>: <result>` line per stage. `scripts/agent/next-stage.sh` decides
   what runs next and where to stop, from the files in `.work/<id>/`.

Answer every stop in that same chat.

**Fixing work you started by hand** (ADR 0004): run `/start-task 86c1abcde --mr 142`
for your own open MR, or `--branch <branch>` for a branch with no MR yet. The
task runs the same route on that branch: the planner ticks what your commits
already cover, the reviewer and fix loop work on it, and the shipper updates
your MR, keeping your title and description. A teammate's MR is refused: use
`/review-mr` for that.

### Stops and what to reply

At a stop you see a `⏸ DECISION NEEDED` block with the reason, the files to
read, the last stage's **Result:** line and what replying does. Reply with:

- **`approve`** (or `approved`, `yes`, `go`, `go ahead`, `ship it`, `lgtm`, with
  nothing else) moves the run on. If the stop can't be approved yet (say, the
  evidence isn't approved at HEAD), you're told why and the stop stays.
- **Anything else** goes to the stage the stop is about as feedback, and the
  stop comes back with its answer. "Yes, but …" is feedback too.
- **`retry`** or **`continue`** checks again after you changed a file by hand.

An approval holds only for what you saw. If the file a stop is about changes
afterwards, the stop comes back.

| Stop | When | What to do |
|---|---|---|
| `requirements` | Always, once requirements.md is written | Answer its open questions, or approve it |
| `plan` | A Stop flag in plan.md (requirement gaps, migration, feature flag, other team) or more than 6 slices | Review plan.md, then approve or say what to change |
| `review` | A finding without a clear decision (including a blocker recommended debt or skip), or a fix routed to requirements or re-plan | Decide those findings in code-review.md |
| `fix-limit` | `MAX_AUTO_FIX_ROUNDS` fix rounds used and the work still needs fixing | Approve for more rounds, or say how to go on |
| `stalled` | A stage ran and changed nothing | Read its **Result:** line in the block. Approve to run it once more, or say how to go on. When it's the planner updating plan.md for changed requirements, approving keeps the plan as it is |
| `pre-ship` | Before the push | Review evidence.md, mr.md and auto-decisions.md, tick the evidence, run `scripts/agent/approve-evidence.sh <id>` in your own terminal, then approve. This approval is your push confirmation. |
| `duo` | After a Duo round: ASK threads, or fixes not yet pushed | Review review-triage.md, then approve the push or answer the ASK threads |
| `spec` | MR review: no ClickUp task found for the MR | Reply with a ClickUp task id or the acceptance criteria, or approve reviewing against the MR description alone (the report says the spec check was weak) |
| `focus` | MR review: the MR changes more than `MR_REVIEW_MAX_FILES` files (lockfiles and generated files don't count) | Reply with what to review, or approve to review the files with the most churn |
| `findings` | MR review: always, once the review is written | Mark each finding in code-review.md post, debt or skip, then approve. Each post asks for your confirmation |
| `plan`, `review`, `duo`, `verify`, `evidence`, `spec`, `focus` | The reason says a file is missing a line the router reads: plan.md's Stop flags, code-review.md after a review, review-triage.md's `Round:` or a Verdict other than `FIX`, `PUSH BACK` or `ASK`, verification.md's `Result:` or `Commit:`, evidence.md's `Commit:`, requirements.md's `Spec source:` in an MR review. Or, for `focus`, the MR's target branch can't be read: run `/review-mr <iid>` again | No approval passes it. Say what's wrong and the stage writes the file again, or fix the file yourself and reply `retry` |

The run ends when the MR is open, and again each time a Duo round is answered: run `/fetch-review <id>` after Duo's next review. An MR review ends once its findings are posted.

### What the stages do in an auto run

Each stage agent knows it's in an auto run because the orchestrator's prompt
starts with `AUTO RUN`. Run by hand, the agents work as before. In an auto run:

- **No stage asks you anything.** Questions and decisions go into the stage's
  files in `.work/<id>/`, and the stop shows them to you.
- **A stage that can't finish** returns `**Result:** blocked: <why>`, and the
  run stops (`stalled`).
- **Requirements** leaves open questions in requirements.md for the
  `requirements` stop.
- **The planner** writes blocking questions as Requirement gaps under
  `## Stop flags`, instead of stopping.
- **The reviewer** sets each finding's decision to its recommendation and logs
  each one in `auto-decisions.md`. It leaves unclear findings for you.
- **The implementer** marks a quick fix that turned out bigger than its
  estimate as `re-plan`, so the `review` stop shows it to you.
- **The shipper** runs twice: once to write mr.md, and once to ship after you
  approve `pre-ship`.
- **The review-responder** triages Duo's threads and commits the fixes without
  waiting for an OK. ASK threads wait for the `duo` stop.
- **In an MR review,** the requirements agent, the verifier and the reviewer
  each follow their "In an MR review" section instead: see "MR review (a
  teammate's MR)".

### Files to check

- **`.work/<id>/status.md`:** where the run stands: `Stage:`, `Pending stop:`,
  `Fix round: <n>/<max>`, and an `Approved <stop>:` line per approval. Only
  `next-stage.sh` writes it. Agents may read it, and the guard denies them any
  change to it, so an agent can't approve a stop.
- **`.work/<id>/run.log`:** the **run log**: one line for each decision
  `next-stage.sh` prints and each stop you approve, oldest first, for example
  `2026-11-19T10:02:11Z stop requirements round=0/2 head=4f2a91c`. Each line has
  the time (UTC), `run`, `stop`, `end` or `approve`, the agent or stop (`-` for
  an end), the fix round and the commit. Read it to see how a run got where it
  is. Only `next-stage.sh` writes it, and agents can't change it. It has no
  token or model counts: Copilot doesn't give them to scripts.
- **`.work/<id>/auto-decisions.md`:** each **auto-decision**: what the pipeline
  decided for you, when, why and under which rule. A plan that went on without
  a stop has an entry, and so does each review finding the reviewer decided.
  Read it before you approve `pre-ship`.

### Fix rounds

A fix round is one return to the implementer: a verifier FAIL, or quick review
fixes (then verify and a delta review). After `MAX_AUTO_FIX_ROUNDS` rounds in a
row (default 2), the run stops at `fix-limit`. Approving it allows that many
more. Rounds start over when a review settles, a Duo round starts, or you
approve `fix-limit` or `review`. Approving `stalled` keeps the count. Set it in `.agent.env`:

```
MAX_AUTO_FIX_ROUNDS=2
```

### Resuming

- **After Duo has reviewed:** pick **pipeline** and run
  `/fetch-review 86c1abcde`. It fetches the threads, then continues the run.
- **After `MAX_REVIEW_ROUNDS` Duo rounds,** the fetch stops with a message. That
  isn't a stop: there's no decision block. Run `/fetch-review 86c1abcde --force`
  to go on.
- **In a new chat, or after a break:** pick **pipeline** and say
  `Continue 86c1abcde` (or `Run 86c1abcde`).

### Pinned models in an auto run

Each stage should run on its pinned model (see "Models (pinned per agent)"):
the orchestrator names the stage's model on every subagent call.

**Confirmed on a paid plan** (#67): with a model other than Auto picked, each
stage runs on its pinned model. Check it in the chat's subagent details. Two
limits remain:
- **Auto cancels the pins.** With Auto picked, every stage runs on Auto.
- **Copilot Free offers only Auto** in Agent Host, so there the run works, but
  not on the pinned models. A `model:` line the plan can't use is ignored
  without any error.

### Optional settings (alerts)

A stop waits for you, so you may want an alert. These are optional, and
nothing in the pipeline depends on them. The installer doesn't touch
`.vscode/settings.json`. Add these yourself if you want them:

```json
{
  "chat.notifyWindowOnConfirmation": "always",
  "accessibility.signals.chatUserActionRequired": { "sound": "on" }
}
```

**Unverified:** the spike didn't confirm whether these fire in Agent Host. A
stop ends the orchestrator's turn; it isn't a confirm prompt, so these may
alert you only for the guard's confirm prompts, not at a stop.

## MR review (a teammate's MR)

The pipeline's second route (ADR 0003): a **read-only review of an MR that
already exists**, usually one a teammate wrote by hand or with another tool. It
reviews the MR against its spec and reports bugs, technical debt and
improvements. It posts only the findings you pick, and it never changes the
MR's code.

### Start

Pick **pipeline** and run `/review-mr <iid> [clickup-id]`. `<iid>` is the MR's
number in its project: the `142` in `!142`. Add the ClickUp task id when the MR
doesn't name its task. Open and draft MRs are fine, including MRs from a fork.
Merged and closed ones are refused.

`/review-mr` checks the MR's head out into a **review worktree** at
`.git/pipeline-reviews/mr-<iid>`. That's a separate checkout, so your branch and
uncommitted work are never touched, and a dirty tree doesn't block it. It sits
in the git folder, where your test runner and linter don't see it. Its work
folder is `.work/mr-<iid>/`.

Dependencies: when the MR's lockfiles match yours, the worktree's
`node_modules` is a link to your checkout's. When the MR changes a lockfile,
`INSTALL_CMD` (default `npm ci`) installs them fresh in the worktree, once per
lockfile version.

An MR review can run while a delivery task is in progress, in a second chat.
They share nothing but the repository.

### The stages and stops

`next-stage.sh mr-<iid>` runs these, in this order:

1. **Spec** (requirements agent): it looks for the ClickUp task in this order:
   the id you passed, then the MR's branch, title and description, then its
   commit messages (`CU-<id>` or `#<id>`). It never guesses. When it finds
   nothing, the run stops at **`spec`**. Reply with a ClickUp id or the
   acceptance criteria, or approve reviewing against the MR description alone.
   In that case the report says the spec check was weak. Gaps in the spec
   become `spec-gap` findings, not questions.
2. **`focus`** stop, only when the MR changes more than `MR_REVIEW_MAX_FILES`
   files (default 40). Files matching `MR_REVIEW_SKIP_PATTERN`, lockfiles and
   generated files by default, don't count. Reply with what to review, or
   approve to review the files with the most churn.
3. **Checks** (verifier): your lint, type check and tests on the MR's head, in
   the worktree. A failure doesn't stop the review: it becomes a blocker or
   major finding.
4. **Review** (reviewer): the MR's open threads first, from people and Duo, so
   it doesn't repeat what's already raised. Then the diff against the spec,
   with the same checklist as delivery.
5. **`findings`** stop, always. In `.work/mr-<iid>/code-review.md`, each
   finding is marked **post**, **debt** (kept in `tech-debt.md`, on your
   machine only) or **skip**, from the reviewer's recommendation. Change any of
   them by replying, then approve.
6. **Post** (reviewer): each finding marked post becomes its own thread on the
   MR, through `scripts/agent/post-review-thread.sh`, and **you confirm every
   post**. A thread sits on the diff line when the finding's line is in the
   diff, and is general otherwise. It starts with
   `**[pipeline review] CR-n · <severity> · <category>**`, so the author can
   tell it's AI-assisted, and it's posted under your GitLab account. There's no
   summary comment.

The run then ends with the counts: posted, parked as debt, skipped.

### Re-review

After the author pushes, run `/review-mr <iid>` again. The worktree moves to
the new head. With no new commits, the run ends at once. Otherwise:
- **Only what's new is reviewed:** the commits since the last review. The focus
  stop counts only the files they change.
- **Each posted finding is checked** and marked verified or still open. New
  findings get new CR numbers, and decisions already made aren't reopened.
- **Replies:** after the findings stop and any new posts, the reviewer replies
  on each verified finding's thread, and you confirm each reply.

It never resolves a thread: that stays with the author and the team.

### Read-only, enforced

The guard denies any change to the review worktree, any commit or push there,
and any ClickUp write for an `mr-<iid>` task. It denies ClickUp writes only for an `mr-<iid>` task id: the guard
keeps no record of which run is going on, so `clickup.sh comment <the ClickUp id>`
still only asks you to confirm, as it does in delivery. Decline it in an MR
review. (`clickup.sh` itself refuses every write for an `mr-<iid>` task.) The only things that leave your
machine are the findings and replies you confirmed. See "Hooks (enforced
rules)".

### Cleanup

The worktree is kept for re-reviews. When you're done (the MR is merged or
closed), run `/review-mr <iid> --done`. It removes the worktree and keeps the
text files in `.work/mr-<iid>/`. `scripts/agent/doctor.sh` warns about review
worktrees whose MR is merged or closed, with the `--done` command for each.

### Settings

In `.agent.env`:

```
INSTALL_CMD="npm ci"          # installs dependencies when the MR changes a lockfile; empty = never
MR_REVIEW_MAX_FILES=40        # more changed files than this: the focus stop
MR_REVIEW_SKIP_PATTERN='…'    # files that don't count (extended regex; see .agent.env.example)
```

**On Copilot Free,** large MRs cost the most tokens: the focus stop caps them,
and a re-review looks only at new commits.

## Manual mode (fallback)

Use manual mode when an auto run can't be used: say a VS Code update breaks
subagents or pinned models, or you want to drive one stage closely. You pick
each stage agent yourself and follow the **Next:** line at the end of its
reply. The usual path:

| Step | Pick agent / run | Say |
|---|---|---|
| 1 | `/start-task 86c1abcde invoice-export` | (sets up, then tells you to pick requirements) |
| 2 | **requirements** | `Analyse 86c1abcde`. Answer its questions, then say "approved". |
| 3 | **planner** | `Plan 86c1abcde`, then review `plan.md` |
| 4 | **implementer** | `Build 86c1abcde`, then `Next slice` until all slices are done |
| 5 | **verifier** | `Verify 86c1abcde`. FAIL goes back to the implementer. |
| 6 | **reviewer** | `Review 86c1abcde`. Decide per finding; fixes loop back (see "Code review and tech debt"). |
| 7 | **evidence** | `Capture evidence for 86c1abcde`, then review, tick and run `approve-evidence.sh` |
| 8 | **shipper** | `Ship 86c1abcde`. Confirm the push when VS Code asks. |
| 9 | `/fetch-review 86c1abcde` | When Duo has reviewed: hands over to review-responder |
| 10 | **review-responder** | `Triage 86c1abcde`, then approve the table. It commits the fixes without pushing. |
| 11 | **verifier**, then **review-responder** | `Re-verify 86c1abcde`, then `Push and reply 86c1abcde`. Confirm the push. |

After `MAX_REVIEW_ROUNDS` Duo rounds, the fetch script stops and leaves the
rest to you. Fetching the same set of threads again doesn't count as a new round. Picking a later agent too early is safe: each one checks that the
earlier stages are done, and tells you what's missing.

**Start a new chat for each stage** when you pick the next agent. The files
carry the context, so each agent starts small instead of dragging the whole
history along.

## Hooks (enforced rules)

`.github/hooks/pipeline-guard.json` runs `scripts/agent/hooks/pre-tool-guard.sh`
before **every** agent tool call. It turns the pipeline's rules from
instructions into enforcement:

| Decision | What |
|---|---|
| **Ask you** | Anything that publishes: `create-mr.sh`, `push-branch.sh`, `upload-evidence.sh`, and `clickup.sh comment / status / attach`. In an MR review: each `post-review-thread.sh` (a finding posted on the MR) and each `reply-thread.sh mr-<iid>` reply. VS Code shows a confirm prompt, which is your final go-ahead. |
| **Deny** | Running `approve-evidence.sh`, or touching `evidence/APPROVED`, `evidence/UPLOADED` or `verified-head` |
| **Deny** | Running `next-stage.sh` from a subagent, however it's spelled (quoted, through a variable or a glob, piped into a shell). Only the orchestrator runs the auto run's router, so a stage agent can't approve a stop itself. Reading it with `cat`, `grep` or `git diff` is fine. |
| **Deny** | Changing `.work/<id>/state.env` (the task state), `.work/<id>/status.md` (the auto run's record, including stop approvals) or `.work/<id>/run.log` (the run log) through edit tools or the shell. Agents may read them; only the scripts write them. |
| **Deny** | Sourcing the pipeline's scripts (`source scripts/agent/config.sh`, `. scripts/agent/ship-gate.sh`…). Their functions would record a verified commit, approve evidence or change the task state without the scripts' checks. Agents run the scripts instead. |
| **Deny** | Reading or printing secrets: token variables, `printenv`/`env`, `.auth/` sessions, `~/.ssh`, `.netrc`, `.npmrc`, literal `pk_`/`glpat-` tokens |
| **Deny** | Destructive git: force push, remote branch delete, `reset --hard`, `clean -f`, `branch -D`, `checkout -- .`, `--no-verify` |
| **Deny** | Raw `git push`, `glab` write commands, or direct ClickUp API calls (the scripts must be used) |
| **Deny** | In an MR review: changing the review worktree (`.git/pipeline-reviews/`) through edit tools or the shell, committing or pushing there, any ClickUp write for an `mr-<iid>` task, and `reply-thread.sh mr-<iid> … --resolve`. Agents may read the worktree. |
| **Deny** | Raw test, lint and typecheck commands (`npm test`, `npx vitest`, `npx playwright test`, `npx tsc`…), so output always goes through the condensed `run-checks.sh` |
| **Deny** | Agent changes to pipeline config, through edit tools or the shell: agent files (including their pinned models), hooks, the pipeline's skills, `copilot-instructions.md` (or `agent-pipeline.instructions.md` with `--local`), `scripts/agent/`, `.agent.env`. Copying one of these files elsewhere (`cp scripts/agent/x.sh /tmp`) is refused too: the guard can't tell which way a copy goes. |

The agent sees the reason and adjusts. Every ask or deny is logged to
`.work/hooks.log`, so you can see what was blocked. **You** can still edit all
of these files by hand. The guard only applies to agent tool calls.

The second hook, `post-edit-format.sh`, runs `FORMAT_CMD` from `.agent.env`
(e.g. `npx prettier --write`) on every file an agent edits. It's off while
`FORMAT_CMD` is empty.

**Good to know:**
- **Protected paths are matched the same way everywhere.** The guard keeps one list (`scripts/agent/hooks/pre-tool-guard.sh --list-protected`), used for shell commands and edit tools alike, ignoring case and treating `\` as `/`.
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

No Playwright in the project? Screenshot ACs are text instead, and the manifest
says so. To add your own screenshot, save the PNG in `.work/<id>/evidence/` and add
a line for it, like the others: `` - [ ] AC-2 · `AC-2-dialog.png` · what it shows ``.

**Checking the gaps yourself (no Playwright).** When `verification.md` lists
ACs as `PASS (gap)` (their logic is tested, but nothing tested them end to end),
the pre-ship stop points to the **gap-checker** agent. Start your app, pick
**gap-checker** yourself and say "Check the gaps for <id>". It walks each gap AC
in VS Code's built-in browser (no Playwright needed) and writes
`.work/<id>/gap-checks.md`: per AC, `looks right`, `looks wrong` or
`couldn't check`, with what it saw. It changes nothing else, and it never counts
toward `VERIFIED` (ADR 0005). It can't run inside the auto run: VS Code doesn't
give subagents the browser tools. Its screenshots stay in the chat; to keep one
as evidence, save it into `evidence/` yourself.

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
  approval, if anything changed after you approved it, or if new commits
  landed after you approved it.
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
