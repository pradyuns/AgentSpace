# Evals

The evals check that an agent can finish its task while a person keeps using
the Mac. A scripted human types and moves the mouse, and a monitor records the
front app, the cursor and every global input event.

Latest numbers: [RESULTS.md](RESULTS.md).

## Quick checks

These don't touch your desktop:

```sh
swift build -c release
.build/release/agentspace-regression
PYTHONPATH=Evals python3 -m unittest test_display_host test_mcp_adapter
```

`swift test` needs full Xcode, since Command Line Tools don't include XCTest.

## Full run

> [!WARNING]
> The scripted human controls the real mouse and keyboard, and cold starts quit
> TextEdit, Chrome and Safari. Use a VM or a spare user account.

Grant your terminal Accessibility, Screen Recording and Input Monitoring, and
install Google Chrome. Then:

```sh
.build/release/agentspace self-test
.build/release/agentspace-eval --backends auto --trials 5 --duration 3
.build/release/agentspace-eval --scenarios S8,S9,S10 --backends auto,virtual-display --trials 3 --duration 30
```

Results go to `Evals/results/`, which git ignores. Exit code `0` means the
report was written, not that the checks passed. Read `summary.md`.

## Comparing tools

Build each tool from source into `~/competitors/` (or set
`AGENTSPACE_COMPETITORS`):

| Tool | Expected path |
|---|---|
| OpenComputer | `opencomputer/bin/opencomputer.mjs` |
| SpaceO | `SpaceO/.build/release/spaceo` |
| Munim | `munim-computer-use/macos/.build/release/munim-computer-use` |

Then run each tool from both starting states:

```sh
for mode in cold warm; do
  for tool in agentspace opencomputer spaceo munim; do
    .build/release/agentspace-eval --comparison-tool "$tool" \
      --backends auto --scenarios S1,S2,S3,S4,S5 \
      --starting-state "$mode" --trials 3 --duration 3 \
      --output "Evals/results/comparison/$tool-$mode"
  done
done
```

Each tool is driven through its own MCP server by `mcp_adapter.py`.

## Scenarios

| ID | Task |
|---|---|
| S1 | Type exact text into a TextEdit document |
| S2 | Fill and verify a web form in Chrome or Safari |
| S3 | Run TextEdit and Chrome work together for 30 s |
| S4 | Stress the form with repeated edits, clicks and scrolling |
| S5 | Launch and stop apps ten times |
| S6 | Reject bad input and missing targets cleanly |
| S7 | Smoke-test the virtual display |
| S8 | Pick the right backend and read back the result |
| S9 | Type, drag, hover and scroll by coordinates |
| S10 | Mix semantic and visual work while the human switches apps |

## Checks

A **task** passes when its expected result is read back from the app. A
**workflow** also requires every isolation check to pass:

- The human's text came out exactly as typed.
- No agent text leaked into the human's app, and no human text leaked into the agent's.
- The human's front app never changed.
- Every global mouse event came from the scripted human, and the cursor stayed where the human left it.
- The monitor never went more than 100 ms without a sample.
- Every app the agent launched was closed and its temp files removed.

Steps a tool doesn't support are left unscored rather than counted as failures.
