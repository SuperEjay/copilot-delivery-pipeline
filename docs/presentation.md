# From ClickUp task to reviewed merge request

How the Copilot delivery pipeline delivers work today (v2.0), and the MR review
route coming in v2.1. This is the team presentation written out as a document,
one section per slide. The speaker notes are under each slide's **Notes**.

Status as of 2026-11-21.

---

## 1. What it is: Copilot agents that each do one step of delivery

You install it into your own project. It runs in your VS Code, on your Copilot
plan and your own ClickUp and GitLab accounts.

| You decide | It never merges | Nothing to host |
|---|---|---|
| It stops only where a decision is yours: requirements, a risky plan, unclear findings, before the push. | Merging the MR stays with you and your team, every time. | No server and no MCP. ClickUp goes through its REST API, GitLab through `glab`. |

<details><summary>Notes</summary>

Instead of one big chat session, delivery is split into stages, and each stage is
its own Copilot agent with one job. A pipeline agent, the orchestrator, runs them
in order as subagents. You stay in charge of every decision that matters, it
never merges anything, and there's nothing to host: it only runs scripts in your
terminal.

</details>

---

## 2. The delivery route: one command takes a task to an open MR

```mermaid
flowchart TD
    A["1 · You start<br/><b>/start-task</b><br/>Branch, work folder, ClickUp task"]
    B["2 · Can stop<br/><b>requirements</b><br/>Writes the requirements and open questions"]
    C["3 · Can stop<br/><b>planner</b><br/>Small slices, with the files each one touches"]
    D["4 · Runs on its own<br/><b>implementer ⇄ verifier</b><br/>One slice per run, then lint, types and tests"]
    E["5 · Can stop<br/><b>reviewer</b><br/>Each finding: fix, tech debt or skip"]
    F["6 · Runs on its own<br/><b>evidence</b><br/>A screenshot or note per criterion"]
    G["7 · Can stop<br/><b>shipper</b><br/>You approve evidence; it pushes and opens the MR"]
    H["8 · It ends<br/><b>MR open</b><br/>Merging is yours, never the pipeline's"]
    I["After Duo reviews: <b>/fetch-review</b><br/>review-responder fixes, verifier re-verifies,<br/>then it pushes and replies"]

    A --> B --> C --> D --> E --> F --> G --> H --> I
    D -- "fail" --> D
    E -- "quick fix" --> D
    I -- "next Duo review" --> I

    classDef start fill:#f0e5d2,stroke:#8e8276,stroke-width:2px,color:#1c1410
    classDef stop fill:#fbe5d3,stroke:#c2410c,stroke-width:3px,color:#1c1410
    classDef auto fill:#ffffff,stroke:#4d7c0f,stroke-width:3px,color:#1c1410
    class A,H start
    class B,C,E,G,I stop
    class D,F auto
```

Orange boxes **can stop** and wait for you; green boxes **run on their own**.

<details><summary>Notes</summary>

You pick the pipeline agent and run `/start-task` with the ClickUp id.
Requirements reads the whole task, including comments and attachments, and lists
open questions. The planner cuts the work into small slices. The implementer
builds one slice per run and the verifier runs our own lint, type check and
tests; failures loop back. The reviewer does an in-depth review, and for each
finding you decide: fix it, park it as tech debt, or skip it. Evidence captures
a screenshot per acceptance criterion. The shipper writes the MR description,
and once you approve the evidence it pushes and opens the MR. After Duo reviews
the MR, `/fetch-review` starts the response loop.

</details>

---

## 3. Where you decide: the auto run stops only for decisions that are yours

| Stop | When it waits for you |
|---|---|
| Requirements | Always: answer its open questions, or approve |
| Plan | A Stop flag in the plan, or more than 6 slices |
| Review | An unclear finding, or a fix sent back to requirements or planner |
| Pre-ship | Always: you tick the evidence and approve it |
| Duo | Threads that ask you something, or fixes to push |

Any stage also stops if it stalls (changed nothing) or uses up its fix rounds
(`MAX_AUTO_FIX_ROUNDS`).

<details><summary>Notes</summary>

Two stops always happen: approving the requirements, and approving the evidence
before anything is pushed. The others only fire when there's something genuinely
ambiguous. The two safety stops mean it can never spin.

</details>

---

## 4. The ship gate: only verified code is pushed

1. It's the task's own branch.
2. It's the exact commit the checks passed on, recorded as `verified-head`.
3. A new MR needs the evidence approved at that same commit.

All three rules live in one script, `scripts/agent/ship-gate.sh`. A commit added
after verification can't slip out.

<details><summary>Notes</summary>

When the full check suite passes on a clean tree, that commit is recorded as
`verified-head`. The push and MR scripts refuse to push any other commit, so a
commit added after verification can't be pushed until it's verified again. All
of it sits in one file, so it's easy to audit.

</details>

---

## 5. Guardrails: rules the agents can't talk their way past

| | |
|---|---|
| **A guard on every tool call** | A hook blocks secrets, destructive git, raw pushes and edits to the pipeline itself. |
| **Publishing needs you** | Anything that publishes outside your machine asks for your confirmation first. |
| **Tech debt stays local** | Parked findings go to `.work/<task>/tech-debt.md` and are sent nowhere unless you choose. |
| **Token-conscious** | Condensed test output, a file handoff between stages, and re-reviews of new commits only. |

<details><summary>Notes</summary>

The guardrails are enforced by scripts and hooks, not by asking the model nicely.
A hook runs before every agent tool call.

</details>

---

## 6. Models: each stage gets the model that suits its job

| Agent | Model | Why |
|---|---|---|
| requirements, planner | Claude Opus 5.5 | Misreading the ticket or the design is the costliest mistake |
| implementer | Claude Sonnet 5.5 | Most tokens are spent here: solid work at mid price |
| verifier, reviewer | GPT-6 Sol | Another model family grades the code more independently |
| evidence | Claude Sonnet 5.5 | Reliable Playwright specs and screenshot checks |
| review-responder | Grok 4.7 | Triage and small fixes, cheap output |
| shipper, pipeline | GPT-6 Luna | Mechanical work: the cheapest model |

Never pick **Auto** in the model picker (it overrides the pins) or a fast or
priority mode (several times the cost).

---

## 7. New in v2.1: review a teammate's MR with one command

```mermaid
flowchart TD
    A["1 · You start<br/><b>/review-mr #lt;iid#gt;</b><br/>Checks the MR out in its own worktree"]
    B["2 · Can stop<br/><b>spec</b><br/>Finds the ClickUp spec, or asks you"]
    C["3 · Can stop<br/><b>focus</b><br/>Asks where to look on very large MRs"]
    D["4 · Runs on its own<br/><b>checks</b><br/>Your lint, types and tests; failures are findings"]
    E["5 · Runs on its own<br/><b>reviewer</b><br/>Reviews the diff against the spec"]
    F["6 · Can stop<br/><b>findings</b><br/>You mark each: post, tech debt or skip"]
    G["7 · You confirm each<br/><b>post</b><br/>Posts each marked finding on the MR"]
    H["8 · It ends<br/><b>review done</b>"]
    R["Runs on its own<br/><b>re-review</b><br/>New commits only; marks findings verified or open,<br/>replies on verified threads, never resolves them"]

    A --> B --> C --> D --> E --> F --> G --> H
    H -- "author pushes,<br/>/review-mr #lt;iid#gt; again" --> R
    R --> H

    classDef start fill:#f0e5d2,stroke:#8e8276,stroke-width:2px,color:#1c1410
    classDef stop fill:#fbe5d3,stroke:#c2410c,stroke-width:3px,color:#1c1410
    classDef auto fill:#ffffff,stroke:#4d7c0f,stroke-width:3px,color:#1c1410
    class A,H start
    class B,C,F stop
    class D,E,G,R auto
```

Run `/review-mr 142` for MR !142. When you're done, `/review-mr 142 --done`
removes the worktree. Focus stops only when the MR has more than
`MR_REVIEW_MAX_FILES` files.

<details><summary>Notes</summary>

The same pipeline can now review an MR that already exists. It checks the MR out
into a separate worktree, finds the ClickUp spec (and asks you if it can't), and
on a very large MR asks where to focus. It runs our checks, where failures
become findings, then reviews the diff against the spec. You decide per finding,
and you confirm each post. After the author pushes, running it again reviews only
the new commits.

</details>

---

## 8. Safe to point at someone else's MR

| | |
|---|---|
| **Your work is untouched** | The MR runs in a separate review worktree. Your branch and uncommitted changes stay as they are. |
| **Read-only on the MR** | The review never changes the MR's code. The guard protects the review worktree. |
| **Nothing posts unasked** | A finding reaches the MR only when you mark it post and confirm it. |
| **Threads stay human** | It replies on threads the author fixed, and never resolves them. That stays with people. |

The design is in [ADR 0003](adr/0003-mr-review-a-second-route.md).

---

## 9. How it's built: test-first, decided in the open

| 1,193 | 3 | 6 |
|---|---|---|
| automated checks across 11 test scripts, all passing on main | architecture decision records: the [auto run](adr/0001-auto-run-through-an-orchestrator-and-subagents.md), [making it the main path](adr/0002-v2-auto-run-is-the-main-path.md), and [MR review](adr/0003-mr-review-a-second-route.md) | releases so far, from v1.0.0 to v2.0.0, each tagged on GitHub |

Every change lands on its own branch, test first, with each new test proven to
fail before the fix.

---

## 10. Where it stands: MR review is built; v2.1.0 is next

| Status | What |
|---|---|
| ✅ **Done** | MR review merged to main with its fixes and refactors. Its issues are closed. |
| 🔶 **In progress** | Trying it on a real GitLab MR. So far tested against stubs. Least proven: placing threads on diff lines. |
| ➡️ **Next** | Release v2.1.0 after the trial's fixes. Then a check of pinned models on paid plans (#67). |

---

## 11. What I'd like from the team: help prove it on real work

1. **An MR to review.** Volunteer an open MR so `/review-mr` runs on real GitLab, not stubs.
2. **A small task.** Run one ticket through the delivery route and note where it stopped.
3. **Your feedback.** Which stops are worth keeping, and which can go.

Questions?
