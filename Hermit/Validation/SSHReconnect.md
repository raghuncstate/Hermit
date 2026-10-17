# SSH connection regressions

## Foreground input and display recovery, 1.4.0 (2026101702)

The terminal previously appended a speculative echo to the end of captured tmux
text. It did not know the remote application's cursor position, so a TUI could
show typed text after a right-aligned footer even when SSH delivery failed.
The parent and detail screens could also start competing reconnects. Cached
viewport dimensions were not reliably reapplied to the new control client.

- Render only captured terminal output. Keep immediate typing in the command
  field, but do not represent a local edit as remotely delivered output.
- Coalesce connection attempts; invalidate background connections synchronously.
  Old connection replies and shutdowns cannot replace or close the new client.
- Preserve the exact selected pane on foreground restoration. Disable terminal
  commands until that pane is restored; do not fall back to a different pane.
- Serialize edits, macros, and Enter. Pin queued input to its connection and do
  not replay input after an uncertain acknowledgment. Show an explicit recovery
  state instead, retaining the local draft where possible.
- Bound stalled control commands to eight seconds and complete pending requests
  before awaiting SSH close. Serialize writes in the same order as reply slots.
- Attach control clients with `ignore-size`, reapply the selected display size,
  and stop cancelled keyboard resizes before changing the window.
- Add a one-tap Shift+Left key (`S-Left`, raw sequence `ESC [ 1 ; 2 D`). Keep the
  keyboard focused after Return, including submitting an empty line.
- In landscape with the keyboard open, share a row for keys/composer and hide
  navigation chrome. The Hide Keyboard control restores the normal navigation.

`TmuxForegroundTests` covers connection races, stale queued keys, non-replay,
literal text, edit ordering, remote-only output, resizing, and Shift+Left.
`tools/tests/run_terminal_simulator_tests.py` runs the real terminal UI through
a disposable loopback-only sshd and a uniquely named `hermit-test-` tmux socket.
It checks five portrait foreground cycles plus a landscape cycle, exact input,
raw Shift+Left, repeated Return, and a visible terminal above the keyboard.
It never connects to production hosts or changes their tmux servers. Run only
after obtaining simulator UI automation approval. Physical-device/network-handoff
testing remains separate from these simulator checks.

Final validation on iPhone 17 Pro Max and iPhone SE (3rd generation), iOS 26.5:
the full regression suite passed on each (92 unique tests, 96 parameterized
invocations), as did a separate 12-test terminal fixture suite on each.
There were no failures, skips, or recorded runtime warnings. Portrait and
landscape screenshots were inspected. Release archive, internal-TestFlight
export, signature verification, and bundled-credential/fixture scans passed.

## Linux startup and continuous-output hotfix, 1.3.2 (2026091902)

The 1.3.1 startup acknowledgement check exposed an existing parser assumption:
Ubuntu Bash emits a bracketed-paste-disable sequence and carriage return before
tmux's `ESC P1000p` marker. Removing only the marker left a prefix before
`%begin`, so the initial response was missed and connecting never completed.
The previous Mac-only jump test did not exercise this Linux login-shell prefix.

Discard the login-shell prefix up to the control-mode entry marker, preserving
ordinary captured ANSI text. Add a 15-second startup acknowledgement timeout
that closes only Hermit's SSH client, not the tmux server or its sessions.

Real-network testing also exposed an unbounded capture loop: output arriving
faster than each SSH round trip continually queued another capture, preventing
input/navigation callers from returning. Complete one capture per invocation,
coalesce broader pending history requests, and schedule follow-up reads in a
separate task. Per-request identities and connection generations prevent an
old read or timer from clearing work on a replacement connection.

Verification:

- The new Linux-prefix regression failed against the old parser; it passes
  after the fix, including a split at every byte boundary.
- All 59 Hermit tests and all 356 pinned NIOSSH tests passed.
- iPhone 17 Pro Max / iOS 26.5 simulator: window selection, continuously changing
  output, and 10 reconnect/read-in-flight shutdown cycles passed on each route:
  remote Linux SSH, direct Mac SSH, and Mac SSH through the remote Linux jump
  host and the existing reverse tunnel. All tests used separate tmux sockets.
- Read-only before/after comparison preserved all 21 Mac and 12 remote Linux
  live windows, including their window IDs, pane IDs, and pane process IDs.
- The release archive excludes the simulator profile/key loader and self-test
  code. Test keys and test profile data are never bundled.

## SSH shutdown regression, 1.3.1 (2026091901)

### Cause and fix

The two TestFlight reports from September 19, 2026, both trapped in
`ChildChannelStateMachine.sendChannelWindowAdjust`, called while an SSH channel
was draining buffered input after a local close. `didClose` alone did not guard
the intermediate closing state.

Pin Wellz26/swift-nio-ssh 0.3.7 (`d88989f3d3bb1dfb2a38ce4af598afbf7fc3095c`).
Its `canSendWindowAdjust` guard prevents window-credit messages in closing
states without discarding buffered terminal data. All other dependencies remain
pinned to the previous versions.

Reconnect stress testing also found that tmux's initial attach response could
consume the first queued command, producing an empty session list. The control
client now waits for the attach response before becoming ready. Workspace
operations ignore cancellation and replies from superseded connections instead
of dropping or reopening the replacement connection.

### Verification

- Removed only the new SSH guard in a disposable dependency checkout: the
  upstream regression test reproduced the exact fatal assertion and SIGTRAP.
- Restored the guard: all 356 NIOSSH tests passed, including
  `testWeDontResizeTheWindowAfterSendingCloseButBeforeItIsAcknowledged`.
- All 54 Hermit tests passed on iPhone 17 Pro Max / iOS 26.5 simulator.
- Simulator integration: three continuously streaming windows, 30 direct SSH
  reconnect cycles and 30 through an SSH jump connection. Every cycle verified
  changed output after reconnect and disconnected with a history read in flight.
- A separate tmux socket hosted every test window; no live user sessions were
  modified. The jump test used two SSH connections to the local test host, not
  production hosts. Cellular handoff and physical-device soak testing remain
  outside these automated checks.
- Release archive: 1.3.1, build 2026091901. Simulator-only environment options
  and the test-key loader are excluded from Release builds.

## Repeating the simulator integration test

Install the Debug build in a disposable simulator. On an SSH-reachable test
host, create a separate tmux socket and a session with windows named `alpha`,
`beta`, and `gamma`. Each window must continuously print its own name and a
changing counter. Never use a live workspace or the default tmux socket.

Pass these variables to `simctl launch` with the `SIMCTL_CHILD_` prefix:

| Variable | Value |
| --- | --- |
| `HERMIT_SIM_SEED_PROFILE` | `1` |
| `HERMIT_SIM_HOST_NAME` | A unique test profile name |
| `HERMIT_SIM_HOST` / `HERMIT_SIM_PORT` | Test SSH endpoint |
| `HERMIT_SIM_USER` | Test SSH username |
| `HERMIT_SIM_KEY_PATH` | Existing test key path, never committed or bundled |
| `HERMIT_SIM_TMUX_SESSION` | Disposable test session name |
| `HERMIT_SIM_TMUX_SOCKET` | Disposable test socket name |
| `HERMIT_SIM_SELFTEST_SWITCH` | `1` |
| `HERMIT_SIM_RECONNECT_CYCLES` | `30` |
| `HERMIT_SIM_SELFTEST_JUMP` | `1` to enable SSH jump-host testing |
| `HERMIT_SIM_JUMP_HOST` / `HERMIT_SIM_JUMP_PORT` / `HERMIT_SIM_JUMP_USER` | Jump endpoint; defaults to target endpoint |
| `HERMIT_SIM_TMUX_COMMAND` | Optional executable override; `/usr/bin/false` tests the startup timeout without starting tmux |

Results are written to the app's `Documents/hermit-sim-selftest.json`. Require
`success: true`, the requested number of completed reconnect cycles, and no
failed window or reconnect results. Save direct and jump results separately.
Test a real Linux login shell with bracketed paste enabled, not just a Mac-to-Mac
jump. For a reverse tunnel, the target is the loopback address/forwarded port on
the jump host; the disposable tmux socket belongs on the destination Mac.
Report phases and `startedAt` distinguish a new test from an older saved result.
The intentional startup-timeout test must report the 15-second error instead of
remaining in `connecting`; it is expected to report `success: false`.
After testing, stop only the disposable server using its explicit `-L` socket.
