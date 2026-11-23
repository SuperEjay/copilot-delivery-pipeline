# Spike #113: VS Code browser tools

Throwaway. Delete this folder once [#113](https://github.com/SuperEjay/copilot-delivery-pipeline/issues/113) is settled.
`install.sh` never ships it: only `payload/` is installed.

```bash
spikes/113-browser-tools/wizard.sh                 # scratch project at ~/browser-spike
spikes/113-browser-tools/wizard.sh ~/elsewhere
```

The wizard builds a scratch project (a test page on `localhost:8080`, no Playwright, three probe agents), opens it in VS Code, then walks you through each check:

| Check | Question |
|---|---|
| 1 tool names | Do the individual tool names, or the `browser` set, work in an agent's `tools:`? |
| 3 direct | Can an agent drive the page and read back "You typed: hello"? |
| 4 subagent | Do the tools work when the agent runs as a subagent, as the verifier does in an auto run? |
| 5 save PNG | Can `runPlaywrightCode` write a screenshot to disk, without Playwright in the project? (checked automatically) |
| 6 WSL | Does it work in a WSL window, with or without `workbench.browser.enableRemoteProxy`? |
| 7 cost | Premium requests for one live check |
| 8 Free | Does it work on Copilot Free? (re-run on a Free account) |

Answers are kept in `<scratch>/.spike-results.env`, so a re-run offers them as defaults. At the end it writes `<scratch>/report.md`, prints it, and offers to post it on #113 (only if you confirm).

Needs `bash`, `git`, `curl`, `python3` (serves the test page) and VS Code with Copilot. `gh` is optional, for posting.
