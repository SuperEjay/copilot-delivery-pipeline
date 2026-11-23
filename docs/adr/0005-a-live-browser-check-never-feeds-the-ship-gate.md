---
status: accepted (2026-11-23, after the e2e-without-Playwright grilling; #112)
---

# A live browser check never feeds the ship gate

`E2E_CMD` defaulted to `npx playwright test`. In a project without Playwright, `run-checks.sh <task> all` failed on e2e, the verifier never printed `VERIFIED <sha>`, and `ship-gate.sh` refused the push. The full pipeline stopped because of a tool the project never chose. VS Code now ships browser tools that an agent can drive without installing anything (#113), so it's tempting to let an agent's live click-through count as e2e.

## Decisions

- **Only repeatable checks produce `VERIFIED`.** The ship gate trusts a commit because a script ran fixed commands on it and recorded the result. A **live check** (an agent driving a browser) can't be re-run the same way, and no script can confirm it happened. It never stands in for a check in `run-checks.sh`.
- **A missing e2e tool is a recorded gap, not a failure.** `config.sh` defaults `E2E_CMD` to Playwright only when `package.json` has `@playwright/test`, and to empty otherwise. An empty command prints `SKIP`, still counts toward a full run, and the verifier lists every skipped check under `## Gaps` in `verification.md`.
- **An explicit `E2E_CMD` always wins**, including an explicit empty one. `.agent.env.example` no longer sets it, so a fresh `.agent.env` gets the default.
- **`doctor.sh` says so before a run:** an INFO when e2e will be skipped, and a WARN when `E2E_CMD` runs Playwright but `package.json` has no `@playwright/test`.

## Considered options

- **Let a live browser check pass the e2e check:** removes the blocker, but the gate would rest on an agent's word, which is what the ship gate exists to prevent.
- **Install Playwright for the project:** a dependency, browser binaries and system libraries the team never chose, just to let the pipeline ship.
- **Detect at install time and write `E2E_CMD=""`:** goes stale when the project adds Playwright later. Detecting at run time doesn't.

## Consequences

- **"Verified" can mean "verified without e2e".** The skip is visible in `verification.md`, to the reviewer, and in the MR, but it isn't a failure.
- **Existing `.agent.env` files keep their explicit Playwright line.** `doctor.sh` warns about it when the project has no Playwright.
- **No live checks at all, for now.** The #113 spike found that VS Code's browser tools work for an agent the user picks, but **not for subagents**, and the verifier runs as a subagent in an auto run. Their screenshots also can't be saved as files. So without Playwright, a UI AC whose logic is covered below e2e is `PASS (gap)`, listed under Gaps and shown at the pre-ship stop. An AC no test covers at all still fails (#114). Revisit if subagents get the browser tools.
- **Evidence without Playwright is text.** `capture-evidence.sh` exits 3, and screenshot ACs become Text evidence. PNGs the user saves in `evidence/` are listed and approved like any other file (#114).
