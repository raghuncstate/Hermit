"""Isolated loopback SSH fixture; owns only its temporary sshd, socket and fake agent."""
import argparse
import asyncio
import contextlib
import getpass
import json
import os
from pathlib import Path
import shlex
import socket
import subprocess
import sys
import tempfile
from test_agent_bridge import bridge, FakeWorker


class CompletingWorker(FakeWorker):
    async def run(self, rid, body):
        async def finish():
            await asyncio.sleep(0.4)
            self.release.set()
        asyncio.create_task(finish())
        return await super().run(rid, body)


async def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", required=True, type=Path)
    parser.add_argument("--upstream-host", help="Explicitly opt into an existing, isolated real-provider test bridge over SSH")
    parser.add_argument("--upstream-root", type=Path)
    parser.add_argument("--provider", choices=("codex", "claude"), default="codex")
    args = parser.parse_args()
    if bool(args.upstream_host) != bool(args.upstream_root):
        parser.error("Both upstream arguments are required")
    if args.upstream_root and (not args.upstream_root.is_absolute() or not args.upstream_root.name.startswith(".hermit-chat-live-")):
        parser.error("Only a disposable .hermit-chat-live-* upstream is supported")
    root = args.directory.resolve()
    if root.exists():
        raise RuntimeError("Fixture directory must be new")
    root.mkdir(mode=0o700)
    for name in ("host", "client"):
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(root / name)], check=True)
    # Reserve an unused loopback port, then hand it to the fixture sshd.
    with socket.socket() as available:
        available.bind(("127.0.0.1", 0)); port = available.getsockname()[1]
    state = root / "state"
    owner, server = None, None
    relay = Path(__file__).parents[1] / "hermit_agent_bridge.py"
    if args.upstream_host:
        upstream = shlex.join([str(args.upstream_root / "venv/bin/python"), str(args.upstream_root / "hermit_agent_bridge.py"),
                              "connect", "--state", str(args.upstream_root / "state")])
        command = shlex.join(["/usr/bin/ssh", "-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                              "-o", "ConnectTimeout=12", args.upstream_host, upstream])
    else:
        transcripts = root / ".codex/sessions"
        transcripts.mkdir(parents=True)
        parent = {"type": "session_meta", "payload": {"id": "fixture-parent", "cwd": str(root)}}
        records = [parent,
                   {"type": "event_msg", "payload": {"type": "item_completed", "item": {"type": "UserMessage", "id": "u", "content": [{"type": "Text", "text": "Native fixture question"}]}}},
                   {"type": "event_msg", "payload": {"type": "item_completed", "item": {"type": "AgentMessage", "id": "a", "content": [{"type": "text", "text": "Native fixture answer"}]}}}]
        (transcripts / "parent.jsonl").write_text("".join(json.dumps(r) + "\n" for r in records))
        (transcripts / "helper.jsonl").write_text(json.dumps({"type": "session_meta", "payload": {"id": "fixture-child", "thread_source": "subagent"}}) + "\n" + json.dumps(parent) + "\n")
        claude = root / ".claude/projects/fixture"
        claude.mkdir(parents=True)
        (claude / "parent.jsonl").write_text(json.dumps({"type": "assistant", "sessionId": "fixture-claude", "message": {"content": [{"type": "text", "text": "Native fixture answer"}]}}) + "\n")
        owner = bridge.Bridge(state, root, {"codex": CompletingWorker, "claude": CompletingWorker})
        server = await asyncio.start_unix_server(owner.connection, path=str(state / "bridge.sock"), limit=bridge.MAX_FRAME)
        os.chmod(state / "bridge.sock", 0o600)
        command = shlex.join([sys.executable, str(relay.resolve()), "connect", "--state", str(state)])
    config = "\n".join([
        "Port " + str(port), "ListenAddress 127.0.0.1", "HostKey " + str(root / "host"),
        "PidFile " + str(root / "sshd.pid"), "AuthorizedKeysFile " + str(root / "client.pub"),
        "PasswordAuthentication no", "KbdInteractiveAuthentication no", "UsePAM no", "PermitRootLogin no",
        "StrictModes yes", "AllowUsers " + getpass.getuser(), "AllowTcpForwarding local",
        "PermitOpen 127.0.0.1:" + str(port), "PermitListen none", "X11Forwarding no", "AllowAgentForwarding no",
        "ForceCommand " + command, "LogLevel ERROR", ""])
    (root / "sshd_config").write_text(config)
    process = await asyncio.create_subprocess_exec("/usr/sbin/sshd", "-D", "-e", "-f", str(root / "sshd_config"), stderr=asyncio.subprocess.PIPE)
    try:
        await asyncio.sleep(1)
        if process.returncode is not None:
            raise RuntimeError((await process.stderr.read()).decode())
        settings = {"port": port, "username": getpass.getuser(), "privateKeyPath": str(root / "client"), "publicHostKey": (root / "host.pub").read_text().split()[:2], "cwd": str(args.upstream_root / args.provider if args.upstream_root else root), "live": bool(args.upstream_host), "provider": args.provider}
        (root / "config.json").write_text(json.dumps(settings))
        print("SSH fixture ready: " + str(root / "config.json"), flush=True)
        if server:
            async with server:
                await server.serve_forever()
        else:
            await process.wait()
    finally:
        if process.returncode is None:
            process.terminate(); await process.wait()
        if owner:
            for worker in owner.workers.values(): await worker.close()
            await asyncio.gather(*owner.tasks.values(), return_exceptions=True)
            owner.store.db.close()
        (root / "client").unlink(missing_ok=True)
        (root / "host").unlink(missing_ok=True)
        (root / "config.json").unlink(missing_ok=True)


if __name__ == "__main__":
    try: asyncio.run(main())
    except KeyboardInterrupt: pass
