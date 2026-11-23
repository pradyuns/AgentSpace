# Results

Measured on 23 November 2026 on one Mac (macOS 26.6.2, 12 cores). A scripted
human typed and moved the mouse during every trial. Each tool ran each scenario
3 times from a **cold** start (apps closed) and 3 times from a **warm** start
(apps already open).

## Complete workflows

A workflow counts only if the task's result was read back **and** every
isolation check passed: the human's text, front app, cursor, monitor coverage
and cleanup.

| Task | Start | AgentSpace | OpenComputer | SpaceO |
|---|---|:---:|:---:|:---:|
| S1 Edit a TextEdit document | Cold | 3/3 | 3/3 | 1/3 |
| | Warm | 3/3 | 3/3 | 3/3 |
| S2 Fill a Chrome form | Cold | 3/3 | 0/3 | — |
| | Warm | 3/3 | 0/3 | — |
| S2 Fill a Safari form | Cold | 3/3 | 0/3 | 2/3 |
| | Warm | 3/3 | 0/3 | 3/3 |
| S3 TextEdit and Chrome together for 30 seconds | Cold | 3/3 | 0/3 | — |
| | Warm | 3/3 | 0/3 | — |
| S4 Repeated form edits, clicks and scrolling | Cold | 3/3 | 0/3 | — |
| | Warm | 3/3 | 0/3 | — |
| S5 Launch and stop apps ten times | Cold | 3/3 | — | 3/3 |
| | Warm | 3/3 | — | 3/3 |
| **Total** | **Cold** | **18/18** | **3/15** | **6/9** |
| **Total** | **Warm** | **18/18** | **3/15** | **9/9** |

Each fraction is complete workflows out of scored attempts. `—` means the
attempt wasn't scored:

- **SpaceO, Chrome:** its MCP tools couldn't read back form values.
- **OpenComputer, launch/stop cycles:** it reused running apps instead of launching fresh ones.
- **Munim** isn't shown. Its browser bridge wasn't connected, so no attempt
  could be scored.

**Why the misses happened:**

| Tool | Failed checks |
|---|---|
| OpenComputer | Chrome tasks took over the human's front app. Safari input didn't match in all 6 attempts. |
| SpaceO | Two cold TextEdit trials had monitor gaps over the 100 ms limit. One Safari input didn't match. |

## Speed and memory

Medians from the cold runs. Warm runs were similar.

| Task | Tool | Task time | Startup | Per action | Peak memory |
|---|---|---:|---:|---:|---:|
| S1 TextEdit | AgentSpace | 2.9 s | 1,800 ms | 143 ms | 144 MiB |
| | OpenComputer | **0.9 s** | **366 ms** | **62 ms** | 208 MiB |
| | SpaceO | 7.6 s | 895 ms | 110 ms | 189 MiB |
| S2 Chrome form | AgentSpace | **1.1 s** | **321 ms** | **64 ms** | 963 MiB |
| | OpenComputer | 2.1 s | 933 ms | 99 ms | 962 MiB |

Task time runs from the first action through cleanup. Peak memory is the
sampled maximum across the tool and the apps it launched.

## Visual tasks

A separate run tested the virtual display, 3 trials per cell.

| Task | `auto` route | Virtual display |
|---|:---:|:---:|
| S8 Pick the right backend and read back | 3/3 | 3/3 |
| S9 Type, drag, hover and scroll by coordinates | 3/3 | 3/3 |
| S10 Mixed work while the human switches apps | 2/3 | 3/3 |

The mixed-work miss was a 119 ms monitor gap. The task itself passed.

## Setup

| Tool | Version |
|---|---|
| OpenComputer | `528ea90` |
| Munim | `b816c1e` |
| SpaceO | 1.0.10 |

Tools ran one after another on the same machine, with other background work
stopped. See the
[eval guide](README.md) to run these yourself.
