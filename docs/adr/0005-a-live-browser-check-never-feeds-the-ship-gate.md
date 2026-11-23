---
status: accepted (2026-11-23, after the e2e-without-Playwright grilling; #112)
---

# A live browser check never feeds the ship gate

`E2E_CMD` defaulted to `npx playwright test`. In a project without Playwright, `run-checks.sh <task> all` failed on e2e, the verifier never printed `VERIFIED <sha>`, and `ship-gate.sh` refused the push. The full pipeline stopped because of a tool the project never chose. VS Code now ships browser tools that an agent can drive without installing anything (#113), so it's tempting to let an agent's live click-through count as e2e.

## Decisions

- **Only repeatable checks produce `VERIFIED`.** The ship gate trusts a commit because a script ran fixed commands on it and recorded the result. A **live check** (an agent driving a browser) can't be re-run the same way, and no script can confirm it happened. It can inform how an AC is graded (#114), but it never stands in for a check in `run-checks.sh`.
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
- **The evidence stage still needs Playwright for screenshots.** Text evidence and live checks without Playwright are #114.
