# AgentSpace

**Let an agent use your Mac while you keep working.**

AgentSpace lets a computer-use agent drive apps in the background, through
Accessibility, headless Chrome or its own virtual display. Your mouse, keyboard, and front
app no longer get pushed around when an agent starts or works!

![An agent interrupts note-taking, then AgentSpace fills the form while the notes stay in front](Assets/agentspace-before-after.gif)

## How it works

Each workspace uses one of three control methods:

| Method | Used for | How it controls the app |
|---|---|---|
| CDP | Chrome web tasks | Disposable headless Chrome by default |
| Accessibility (AX) | Native app controls and text | Accessibility actions, value writes, and app-targeted keys |
| Virtual display | Coordinates, hover, drag, and scrolling | An AgentSpace-owned display and helper process |

The default `auto` route uses CDP for Chrome and AX for native apps. Pass
`--interaction visual` to use the virtual display.

You can also opt into existing sessions or persistent agent profiles to reuse
logins (see [Chrome sessions](#chrome-sessions-opt-in)). Connection approval
and a user-requested login handoff can intentionally show Chrome, otherwise by
default actions stay in background tabs.

Every command returns JSON with the method used, whether the result was
verified, and the front app and cursor before and after.

## Results

Tested against two other computer-use tools while a script typed and moved the
mouse like a person would. A workflow passes only if the task was verified **and** the
human's text, front app, cursor and cleanup checks all passed.

| Tool | Cold start | Warm start |
|---|:---:|:---:|
| **AgentSpace** | **18/18** | **18/18** |
| OpenComputer | 3/15 | 3/15 |
| SpaceO | 6/9 | 9/9 |

Each tool was scored only on the scenarios it supports, so the totals differ.
Chrome tasks in this comparison used the default disposable profile. The
comparison predates the authenticated session modes.
AgentSpace was faster on the Chrome form and slower on TextEdit. See
[Evals/RESULTS.md](Evals/RESULTS.md) for per-scenario results, speed and
memory, and [Evals/README.md](Evals/README.md) to run the evals yourself.

## Quick start

Requires macOS 14+, Swift 6 and Google Chrome.

```sh
git clone https://github.com/pradyuns/AgentSpace.git
cd AgentSpace
swift build -c release
export PATH="$PWD/.build/release:$PATH"
agentspace self-test
```

Headless Chrome needs no permissions. For native apps, give your terminal
Accessibility access (and Screen Recording for screenshots) in
**System Settings > Privacy & Security**. If you move the binaries, keep
`agentspace-display-host` and `agentspace-session-broker` (needed for Chrome
session modes) next to `agentspace`. The full build produces both.

Fill a web form without opening a visible browser:

```sh
agentspace create-workspace --workspace web
agentspace launch-app --workspace web --app chrome --file Fixtures/test-page.html
agentspace type-text --workspace web --role AXTextField --title 'Probe input' --replace --text 'Hello'
agentspace click --workspace web --role AXButton --title 'Probe button'
agentspace observe --workspace web --screenshot
agentspace stop-workspace --workspace web
```

Use a virtual display for visual interaction:

```sh
agentspace create-workspace --workspace visual --interaction visual
agentspace launch-app --workspace visual --app chrome --file Fixtures/interactions.html
agentspace observe --workspace visual --screenshot
agentspace stop-workspace --workspace visual
```

Use the screenshot to choose window-local points for `click --x X --y Y`,
`move --x X --y Y`, or `drag --x X --y Y --to-x X --to-y Y`.
Chrome coordinates target page content, not the browser toolbar.

### Connect an agent through MCP

Start the stdio MCP server:

```sh
agentspace mcp
```

Configure your MCP client to run the built `agentspace` executable with
`mcp` as its argument. Each CLI command is also an MCP tool with the same
options and JSON results.

### Chrome sessions (opt-in)

By default, `launch-app --app chrome` uses a throwaway headless profile, so
nothing is signed in. To reuse logins, pass `--chrome-session`:

```sh
agentspace create-workspace --workspace signed-in
agentspace launch-app --workspace signed-in --app chrome \
    --chrome-session existing --url https://mail.google.com \
    --site gmail --expected-account you@gmail.com
```

There are two modes:

- **`existing`** uses your running Chrome. Open
  `chrome://inspect/#remote-debugging`, enable remote debugging, and approve
  the connection when Chrome asks. AgentSpace never relaunches your normal
  profile with debugging flags. If Chrome doesn't answer in time you get
  `approval_unresolved`. That means the prompt went unanswered, not that you
  denied it or that login failed. There are no automatic retries, so wait for
  the idle broker to exit (about 35 seconds) before launching again.
- **`dedicated`** (also pass `--profile NAME`) runs headless Chrome on a
  separate profile that keeps its cookies between tasks. Each profile allows
  one active workspace at a time. Stopping closes Chrome normally so cookies
  save, and never deletes the profile. Downloads go to the broker's
  `downloads/SESSION` folder until you remove them.

`--site gmail` checks that you're signed in. With `--expected-account` it also
checks that it's the right account, using the address shown in Gmail's top
banner (stored only as a salted hash). Other sites report unknown access, and
`--expected-account` blocks on them because identity can't be verified. If the
account is unknown or doesn't match, the agent can't read or type. A sign-in
page blocks input, and AgentSpace refuses to type passwords.

To sign in yourself:

```sh
agentspace session-handoff --workspace signed-in
# Complete sign-in in Chrome yourself.
agentspace session-resume --workspace signed-in
```

During handoff, automation pauses and Chrome behaves normally. In `existing`
mode only the agent's tab comes forward, so switch away from it before
resuming. In `dedicated` mode the profile reopens with a window and goes back
to headless on resume. If the login check still fails, you stay in handoff.
Tabs you open yourself are never touched.

AgentSpace only works with tabs it created. It never reads, activates or
closes yours. In the background it keeps popups and link targets inside the
agent's tab, and in `existing` mode it blocks downloads. These are page-level
hooks, not a security sandbox. For pages that need popups or downloads, use a
`dedicated` profile.

If stop can't confirm cleanup, it keeps the workspace binding so you can try
again. `--abandon-session` drops the binding without cleaning up. If the broker
reports `broker_recovery_required`, restart that Chrome before launching again.

If input was sent but couldn't be verified, the error includes
`verified: false` and `retrySafe: false`. Don't retry it automatically, since
the action may already have happened.

Full URLs stay in memory, and action logs keep only status fields. Screenshots
come back inline as base64 PNG data, and nothing is written to disk.

The existing benchmark results describe the default disposable browser mode.
They do not measure these opt-in session modes.

Build and run the checks with Chrome installed:

```sh
swift build --product agentspace
swift build --product agentspace-session-broker
swift build --product agentspace-display-host
swift build --product agentspace-regression
.build/debug/agentspace-regression
AGENTSPACE_TEST_HEADED=1 python3 -m unittest Evals.test_chrome_session Evals.test_session_transport -v
swift build -c release --product agentspace
PYTHONPATH=Evals python3 -m unittest Evals.test_display_host Evals.test_mcp_adapter -v
```

The session suite uses isolated fixture profiles and independently checks
Chrome targets and download files. The headed run exercises real cookie-backed
login across headed/headless transitions and a separate human control tab's
selection, focused input, scroll, and OS foreground during CLI work. Set
`AGENTSPACE_TEST_CHROME` to override the fixture Chrome executable. These
fixtures do not prove real Chrome consent, Gmail multi-account behavior, or
real-site MFA. Those need a separate human check. XCTest remains unavailable
in a Command Line Tools-only installation.

## Commands

Every command accepts `--workspace NAME` and returns one JSON object.
CLI failures return a nonzero exit code.

| Command | Purpose |
|---|---|
| `create-workspace` | Create workspace state |
| `launch-app` | Launch TextEdit, Safari, Chrome, or an installed bundle ID |
| `prepare` | Create a workspace with visible Chrome before you start work |
| `observe` | Read the UI, and add `--screenshot` to capture it |
| `click`, `type-text`, `key`, `scroll` | Act on a UI element |
| `move`, `drag` | Use visual pointer actions |
| `target-window` | Select a workspace window |
| `get-status` | Inspect routing, permissions, readiness, and recent actions |
| `session-handoff`, `session-resume` | Give the session tab to you for sign-in, then hand it back |
| `stop-workspace` | Quit owned apps, release the display, and remove temporary files |
| `list-workspaces`, `self-test` | List workspaces or check prerequisites |

Common options:

| Option | Meaning |
|---|---|
| `--backend auto\|cdp\|ax\|virtual-display` | Select a route at first launch |
| `--interaction semantic\|visual` | Declare the interaction needed |
| `--app`, `--file`, `--url` | Choose the app and content to open |
| `--ref` or `--role` with `--title` / `--label` | Address a control from `observe` |
| `--text TEXT --replace` | Replace an editable value and check the result |
| `--key return` / `--key cmd+a` (native apps) | Send a key or supported shortcut |
| `--x`, `--y`, `--to-x`, `--to-y` | Use window-local visual coordinates |
| `--button right` / `--count 2` | Request a right-click or double-click |
| `--direction down --amount 1` | Scroll a selected area |
| `--chrome-session existing\|dedicated` | Reuse a persistent browser via the session broker |
| `--profile`, `--site`, `--expected-account` | Name a dedicated profile, declare site rules, require a signed-in account |

## Limitations

- Native control only works as well as the app's Accessibility support.
- The virtual display relies on private Apple APIs that can change between
  macOS releases. `agentspace self-test` checks whether they're available.
- `--chrome-session existing` only sees Chrome instances that already
  advertise remote debugging (DevToolsActivePort). It never enables the
  flag or touches profile settings itself.
- Site and account checks only cover the declared `--site` rules. Anything
  else reports `unknown` rather than guessing.
- Not a sandbox!!

## License

[MIT](LICENSE)
