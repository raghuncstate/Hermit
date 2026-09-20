# Shift keys, 1.3.3 (2026092001)

The pinned Shift toggle arms the next toolbar key. Tab becomes tmux `BTab`;
Up, Down, Left, and Right become `S-Up`, `S-Down`, `S-Left`, and `S-Right`.
Other toolbar keys are unchanged and consume the one-shot modifier. Typing,
submitting input, changing panes/windows, and leaving the screen clear Shift.
The software keyboard's own Shift key remains independent.

## Verification

- 63 Hermit tests passed, including all five shifted mappings, unchanged normal
  and literal keys, non-consuming label previews, and one-shot reset.
- iPhone 17 Pro Max simulator connected to remote Linux, directly to the Mac,
  and through Linux as a jump host to the Mac's existing reverse SSH tunnel.
  Each route verified ten exact terminal byte sequences: each Shift combination
  followed by its unshifted key. All 30 checks passed.
- Inspected the simulator screenshot of the terminal with the pinned Shift
  control and horizontally scrolling macro ribbon.
- No working tmux sessions were used for input tests.

## Repeat

Start `read-terminal-keys.py` in a new window named `keys`, in a disposable
session on a dedicated tmux socket beginning with `hermit-test-`. Never use the
default socket. The reader must be freshly started for each test run because
it numbers the received keys. Do not respawn any live workspace pane.

Use the Debug simulator setup documented in `SSHReconnect.md`, plus these
environment options with the `SIMCTL_CHILD_` prefix for `simctl launch`:

- `HERMIT_SIM_SELFTEST_SWITCH=1`
- `HERMIT_SIM_SELFTEST_KEYS=1`
- `HERMIT_SIM_TMUX_SESSION`: the disposable session name
- `HERMIT_SIM_TMUX_SOCKET`: the dedicated `hermit-test-` socket
- `HERMIT_SIM_SHOW_TEST_WINDOW=1`: optionally open the tested terminal for a
  screenshot after a successful direct-host run (not needed for SSH verification)

Require `success: true` and ten successful `keyResults` in
`Documents/hermit-sim-selftest.json`. The key test refuses to send input without
both the dedicated socket name and the raw key reader's readiness marker.
Simulator seeding, key loading, and this test runner are excluded from Release.
