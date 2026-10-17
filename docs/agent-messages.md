# Agent Messages Beta

Messages is an opt-in native conversation interface alongside the existing
tmux terminal. Enable **Settings > Agent messaging** after installing the private
host service on each intended host. Existing server profiles and SSH keys remain
on the phone; no agent credential or SSH private key is packaged in the app.

## Host Installation

Requirements: Python 3.10+, an installed Codex executable for Codex conversations,
and the host user's existing agent account authentication. Claude uses its saved
Claude.ai or Console account, not inherited API-key or alternate-provider routing.
Authentication is host-local; this installer neither signs in nor copies credentials.

```sh
python3 tools/install-hermit-agent-bridge.py --dry-run
python3 tools/install-hermit-agent-bridge.py --python /path/to/python3 --start
```

The installer creates an isolated SDK environment and a separate user LaunchAgent
on macOS or user-systemd service on Linux. Python installations without `ensurepip`
need an existing pip with `--python` support. The install does not require root.
It refuses to replace an existing installation or interrupt an active service.
It does not change the reverse tunnel, SSH keys, tmux options, or restore jobs.

The phone executes `~/.local/bin/hermit-agent-bridge connect` over authenticated
SSH, with independent target/jump host-key verification. The daemon listens only
on a user-owned Unix socket. State is in `~/.local/state/hermit-agent-bridge`.
User services are not a promise of pre-login operation. The Mac starts its service
at user login; Linux follows the existing user-manager lifetime.

## Scope and Safety

- New bridge-owned Codex and Claude conversations support streaming replies,
  interruption, and durable delivery receipts. A disconnected phone does not stop
  the worker. Uncertain sends are never automatically replayed.
- Native terminal histories are read-only in Messages. Continue existing tmux
  conversations in Terminals; the bridge never sends tmux keystrokes or adopts a
  running terminal process.
- A service or host restart retains history but does not automatically resume
  workers. Prior conversations become read-only and interrupted delivery may be
  unknown. Safe explicit resumption is future work.
- New Codex workers use full access with no approval prompts, with an explicit
  acknowledgement in the creation form. Claude uses SDK default permission mode
  and preserves applicable host/project policy. Existing allow rules still apply.
- The host service has the SSH user's privileges. Private file/socket permissions
  are not a sandbox against another process with that user's identity or root.
- Voice is foreground-only, on-device recognition followed by speech playback.
  Sending requires a final transcript after the configured quiet period. Pasted
  content is not microphone authorization. Real-device audio and headset testing
  remain necessary; no full-duplex or background-voice guarantee is made.
- No external chat service, automatic URL opening, OAuth callback forwarding,
  offline execution queue, or push notifications are introduced.

The old terminal remains available. Disabling Agent messaging bypasses its
separate cache without migrating the terminal's existing data or keys.

## Verification

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tools/tests -p test_agent_bridge.py -v
```

`tools/tests/run_agent_simulator_tests.py` uses a disposable pinned loopback SSH
fixture and fake workers by default. `--upstream-host`, `--upstream-root`, and
`--provider claude` or `codex` explicitly enable real-inference tests against a
separate private test bridge. Never point these at an existing terminal agent.

`tools/tests/run_live_agent_bridge_tests.py` creates only new test conversations
under a private `.hermit-chat-live-*` project directory. Its installed-service
mode refuses a bridge with live conversations and closes only workers it creates.
It does not install or restart services, and it never operates tmux itself.
