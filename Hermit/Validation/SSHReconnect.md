# SSH shutdown regression, 1.3.1 (2026091901)

## Cause and fix

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

## Verification

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
| `HERMIT_SIM_SELFTEST_JUMP` | `1` to SSH through the same test host |

Results are written to the app's `Documents/hermit-sim-selftest.json`. Require
`success: true`, the requested number of completed reconnect cycles, and no
failed window or reconnect results. Save direct and jump results separately.
After testing, stop only the disposable server using its explicit `-L` socket.
