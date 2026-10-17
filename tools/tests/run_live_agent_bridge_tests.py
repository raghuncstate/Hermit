#!/usr/bin/env python3
"""Opt-in, real-inference tests using new isolated Hermit conversations.

Never installs a service, attaches to an existing agent, or runs tmux commands.
The caller starts `serve` inside its own disposable tmux server. `exercise`
connects over SSH and creates only new conversations below the test directory.
An explicit --installed-service instead exercises an idle installed bridge;
--host local uses its stdio launcher without SSH. Neither restarts a service.
"""
import argparse
import asyncio
import contextlib
import importlib.util
import json
import os
from pathlib import Path
import shlex
import signal
import sys
import time
import uuid


class RPCError(Exception):
    pass


class Client:
    def __init__(self, host, root, installed=False):
        self.host, self.root = host, root
        self.installed = installed
        self.process = None
        self.reader = None
        self.pending = {}
        self.host_id = None
        self.events = 0

    async def connect(self):
        if self.installed:
            command = [str(Path.home() / ".local/bin/hermit-agent-bridge"), "connect"] if self.host == "local" else ["~/.local/bin/hermit-agent-bridge", "connect"]
        else:
            command = [str(self.root / "venv/bin/python"), str(self.root / "hermit_agent_bridge.py"),
                       "connect", "--state", str(self.root / "state")]
        argv = command if self.host == "local" else self.ssh() + [
            "~/.local/bin/hermit-agent-bridge connect" if self.installed else shlex.join(command)]
        self.process = await asyncio.create_subprocess_exec(
            *argv, stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL, limit=1024 * 1024)
        self.reader = asyncio.create_task(self.read())
        hello = await self.rpc("hello")
        assert hello["version"] == 1
        if self.host_id is not None:
            assert self.host_id == hello["hostID"], "Reconnect reached a different bridge"
        self.host_id = hello["hostID"]

    def ssh(self):
        return ["ssh", "-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=12", self.host]

    async def read(self):
        try:
            while line := await self.process.stdout.readline():
                value = json.loads(line)
                future = self.pending.get(value.get("id"))
                if future is not None and not future.done():
                    if "error" in value:
                        future.set_exception(RPCError(value["error"]))
                    else:
                        future.set_result(value["result"])
                elif value.get("method") == "changed":
                    self.events += 1
        finally:
            for future in self.pending.values():
                if not future.done():
                    future.set_exception(RPCError("SSH test relay disconnected"))

    async def rpc(self, method, **params):
        rid = str(uuid.uuid4())
        if method != "hello":
            params.setdefault("hostID", self.host_id)
        future = asyncio.get_running_loop().create_future()
        self.pending[rid] = future
        try:
            self.process.stdin.write(json.dumps({"id": rid, "method": method, "params": params}).encode() + b"\n")
            await self.process.stdin.drain()
            return await asyncio.wait_for(future, 60)
        finally:
            self.pending.pop(rid, None)

    async def close(self):
        if self.process is not None and self.process.returncode is None:
            self.process.terminate()
            await asyncio.wait_for(self.process.wait(), 10)
        if self.reader:
            self.reader.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await self.reader


async def serve(root):
    if not root.name.startswith(".hermit-chat-live-") or root.parent != Path.home():
        raise ValueError("Use a private, disposable .hermit-chat-live-* directory in this user's home")
    if root.is_symlink() or root.stat().st_mode & 0o077:
        raise ValueError("Test directory must be private and not a symlink")
    spec = importlib.util.spec_from_file_location("bridge", root / "hermit_agent_bridge.py")
    bridge = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(bridge)
    for name in ("discovery", "codex", "claude", "permission"):
        (root / name).mkdir(mode=0o700, exist_ok=True)
    settings_dir = root / "claude/.claude"
    settings_dir.mkdir(mode=0o700, exist_ok=True)
    settings = settings_dir / "settings.local.json"
    expected = {"permissions": {"ask": ["Write", "Edit", "Bash"]}}
    if settings.exists():
        if json.loads(settings.read_text()) != expected:
            raise ValueError("Test-local permission configuration changed")
    else:
        with settings.open("x") as output:
            json.dump(expected, output)
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, stop.set)
    task = asyncio.create_task(bridge.serve(root / "state", root / "discovery"))
    waiting = asyncio.create_task(stop.wait())
    try:
        done, _ = await asyncio.wait([task, waiting], return_when=asyncio.FIRST_COMPLETED)
        if task in done:
            await task
    finally:
        task.cancel()
        waiting.cancel()
        await asyncio.gather(task, waiting, return_exceptions=True)


async def exercise(args):
    client = Client(args.host, args.root, args.installed_service)
    created, results = [], []
    report = {"host": args.host, "testRoot": str(args.root), "installedService": args.installed_service, "started": time.time(), "checks": results}

    def passed(check, **extra):
        results.append({"check": check, "passed": True, **extra})
        print(json.dumps(results[-1]), flush=True)

    async def rejected(method, **params):
        try:
            await client.rpc(method, **params)
        except RPCError:
            return
        raise AssertionError(method + " unexpectedly succeeded")

    async def completed(cid, rid, timeout=180, allow=None):
        deadline = time.monotonic() + timeout
        streaming, questions = set(), []
        while time.monotonic() < deadline:
            history = await client.rpc("history", conversation=cid)
            streaming.update(m["id"] for m in history["messages"] if m["status"] == "streaming")
            if history.get("question"):
                q = history["question"]
                questions.append(q)
                if allow is None:
                    await client.rpc("answer", conversation=cid, questionID=q["id"], allow=False)
                    raise AssertionError("Unexpected tool approval during a tool-free test")
                await rejected("answer", conversation="unrelated-test-id", questionID=q["id"], allow=True)
                await client.rpc("answer", conversation=cid, questionID=q["id"], allow=allow(q))
                await rejected("answer", conversation=cid, questionID=q["id"], allow=True)
            receipt = await client.rpc("receipt", conversation=cid, requestID=rid)
            if receipt["status"] not in ("accepted", "working"):
                # Completion can arrive between the two RPCs; inspect history after it.
                history = await client.rpc("history", conversation=cid)
                return receipt, history, streaming, questions
            await asyncio.sleep(0.15)
        raise AssertionError("Timed out waiting for real agent turn: " + cid)

    async def turn(cid, body):
        rid = str(uuid.uuid4())
        await client.rpc("send", conversation=cid, requestID=rid, text=body)
        return rid

    async def check_marker(path, expected):
        code = "import pathlib,sys; p=pathlib.Path(sys.argv[1]); expected=sys.argv[2]; assert (p.read_text().strip()==expected if expected else not p.exists())"
        command = [str(args.root / "venv/bin/python"), "-c", code, str(path), expected]
        process = await asyncio.create_subprocess_exec(*(command if args.host == "local" else client.ssh() + [shlex.join(command)]))
        assert await asyncio.wait_for(process.wait(), 15) == 0, "Permission test marker mismatch"

    try:
        await client.connect()
        assert all(c["status"] in ("closed", "failed", "offline") for c in (await client.rpc("list", discover=False))["conversations"]), "Test bridge still has live workers"
        await rejected("create", hostID="incorrect-host", requestID=str(uuid.uuid4()), provider="codex", title="Must not create", cwd=str(args.root / "codex"))
        passed("wrong-host creation rejected")
        for provider in args.providers:
            cid = str(uuid.uuid4())
            created.append(cid)
            await client.rpc("create", requestID=cid, provider=provider, title="Hermit live test " + provider, cwd=str(args.root / provider))
            passed(provider + " real worker started", conversation=cid)
            token = "hermit-" + uuid.uuid4().hex[:12]
            prompt = ("This is an isolated messaging transport test. Do not use tools, inspect files, create agents, or modify anything. "
                      "Remember this nonce for the next question: " + token + ". Reply with exactly that nonce, nothing else.")
            rid = await turn(cid, prompt)
            await rejected("send", hostID="incorrect-host", conversation=cid, requestID=str(uuid.uuid4()), text="do not deliver")
            await rejected("interrupt", conversation=cid, requestID="unrelated-turn")
            receipt, history, streaming, _ = await completed(cid, rid)
            assert receipt["status"] == "completed", (provider, receipt, history)
            replies = [m for m in history["messages"] if m["role"] == "assistant"]
            assert len(replies) == 1 and replies[0]["text"].strip() == token, (provider, replies)
            assert replies[0]["status"] == "complete", replies
            passed(provider + " completed real reply", backend=(await client.rpc("list", discover=False))["conversations"][0]["backend"], streamingRows=len(streaming))
            duplicate = await client.rpc("send", conversation=cid, requestID=rid, text=prompt)
            assert duplicate["status"] == "completed"
            await rejected("send", conversation=cid, requestID=rid, text="changed request body")
            passed(provider + " duplicate send and wrong target protected")

            rid2 = await turn(cid, "No tools. What was the nonce in my previous message? Reply with exactly that nonce, nothing else.")
            await client.close()
            await asyncio.sleep(2)
            await client.connect()
            receipt2, history2, _, _ = await completed(cid, rid2)
            assert receipt2["status"] == "completed", (provider, receipt2, history2)
            assert [m for m in history2["messages"] if m["role"] == "assistant"][-1]["text"].strip() == token
            assert len([m for m in history2["messages"] if m["role"] == "user"]) == 2
            passed(provider + " retained context and continued across SSH disconnect")

            rid3 = await turn(cid, "No tools and no file access. Generate 500 numbered lines, each stating 'Hermit streaming transport line' with its number. Start directly with line 1.")
            deadline = time.monotonic() + 120
            saw_stream = False
            while time.monotonic() < deadline:
                h = await client.rpc("history", conversation=cid)
                current = h["messages"][len(history2["messages"]):]
                saw_stream = any(m["role"] == "assistant" and m["status"] == "streaming" and len(m["text"]) > 80 for m in current)
                if saw_stream:
                    break
                if (await client.rpc("receipt", conversation=cid, requestID=rid3))["status"] not in ("accepted", "working"):
                    break
                await asyncio.sleep(0.1)
            assert saw_stream, provider + " did not expose streaming output"
            await client.rpc("interrupt", conversation=cid, requestID=rid3)
            interrupted, interrupted_history, _, _ = await completed(cid, rid3)
            assert interrupted["status"] == "interrupted", (provider, interrupted, interrupted_history)
            assert not any(m["status"] == "streaming" for m in interrupted_history["messages"]), "Interrupted output still presented as streaming"
            passed(provider + " streaming and exact-turn interruption")

            rid4 = await turn(cid, "No tools. Reply with the single word RECOVERED, no punctuation.")
            recovered, h4, _, _ = await completed(cid, rid4)
            assert recovered["status"] == "completed", (provider, recovered, h4)
            assert [m for m in h4["messages"] if m["role"] == "assistant"][-1]["text"].strip() == "RECOVERED", h4
            passed(provider + " next turn works after interruption")
            if provider == "claude":
                for approved in (False, True):
                    marker = args.root / "permission" / (str(uuid.uuid4()) + ".txt")
                    text = "APPROVED_TEST_MARKER"
                    prompt = ("This is an isolated permission test. Use ONLY the Write tool exactly once to create " + str(marker)
                              + " containing exactly " + text + ". Do not inspect or change anything else, and do not use Bash or other tools. "
                              "If denied, do not retry or find another method. Reply DENIED or WRITTEN based on the tool result.")
                    request = await turn(cid, prompt)
                    def allow(question):
                        detail = json.loads(question["detail"])
                        assert question["title"] == "Write" and detail.get("file_path") == str(marker), "Unexpected tool request"
                        assert detail.get("content", "").strip() == text, "Unexpected marker content"
                        return approved
                    receipt, _, _, questions = await completed(cid, request, allow=allow)
                    assert receipt["status"] == "completed" and questions, "Real tool approval was not observed"
                    await check_marker(marker, text if approved else "")
                    passed("claude permission " + ("allow" if approved else "deny") + " honored and cross-conversation answer rejected")
            await client.rpc("close", conversation=cid)
            passed(provider + " owned worker closed without deleting conversation")
        passed("SSH change notifications received", count=client.events)
        report["passed"] = True
    except Exception as error:
        report["passed"] = False
        report["failure"] = str(error)
        print("Live test failed; details saved in the private report.", flush=True)
        raise
    finally:
        for cid in created:
            with contextlib.suppress(Exception):
                h = await client.rpc("history", conversation=cid)
                if h.get("requestID"):
                    await client.rpc("interrupt", conversation=cid, requestID=h["requestID"])
                    await completed(cid, h["requestID"], timeout=30, allow=lambda _: False)
                await client.rpc("close", conversation=cid)
        await client.close()
        report["finished"] = time.time()
        args.report.write_text(json.dumps(report, indent=2) + "\n")
        args.report.chmod(0o600)


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("serve", "exercise"))
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--host")
    parser.add_argument("--report", type=Path)
    parser.add_argument("--installed-service", action="store_true", help="Explicitly test a new idle installed service; creates and closes only new test conversations")
    parser.add_argument("--providers", nargs="+", choices=("codex", "claude"), default=["codex", "claude"])
    args = parser.parse_args()
    if not args.root.is_absolute() or not args.root.name.startswith(".hermit-chat-live-"):
        parser.error("root must be an absolute, disposable .hermit-chat-live-* directory")
    if args.command == "exercise" and (not args.host or not args.report):
        parser.error("exercise requires --host and --report")
    if args.host == "local" and (not args.installed_service or args.root.parent != Path.home()):
        parser.error("Local tests require an installed service and a private test directory in this user's home")
    asyncio.run(serve(args.root) if args.command == "serve" else exercise(args))


if __name__ == "__main__":
    main()
