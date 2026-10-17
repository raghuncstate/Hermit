import asyncio
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import sys
import types
import unittest
from unittest.mock import patch
import uuid

spec = importlib.util.spec_from_file_location("bridge", Path(__file__).parents[1] / "hermit_agent_bridge.py")
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


class FakeWorker:
    def __init__(self, owner, cid):
        self.owner, self.cid = owner, cid
        self.runs = []
        self.release = asyncio.Event()
        self.interrupted = False

    async def open(self, cwd):
        return "test-backend-" + self.cid

    async def run(self, rid, body):
        self.runs.append((rid, body))
        self.owner.delta(self.cid, "answer", "Hello ")
        self.owner.delta(self.cid, "answer", "world")
        await self.release.wait()
        self.owner.message(self.cid, "answer", "assistant", "Hello world")
        return "interrupted" if self.interrupted else "completed"

    async def interrupt(self):
        self.interrupted = True
        self.release.set()

    async def close(self):
        self.release.set()


class BridgeTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="hermit-bridge-test-")
        self.home = Path(self.tmp.name) / "home"
        self.home.mkdir(mode=0o700)
        self.state = Path(self.tmp.name) / "state"
        self.bridge = bridge.Bridge(self.state, self.home, {"codex": FakeWorker, "claude": FakeWorker})
        self.host = self.bridge.store.host_id
        self.cid = str(uuid.uuid4())
        await self.call("create", requestID=self.cid, provider="codex", title="Fixture", cwd=str(self.home))

    async def asyncTearDown(self):
        for worker in self.bridge.workers.values():
            await worker.close()
        await asyncio.gather(*self.bridge.tasks.values(), return_exceptions=True)
        self.bridge.store.db.close()
        self.tmp.cleanup()

    async def call(self, method, **params):
        return await self.bridge.dispatch(method, {"hostID": self.host, "conversation": self.cid, **params})

    async def test_wrong_host_rejected_before_write(self):
        with self.assertRaisesRegex(bridge.BridgeError, "Host identity"):
            await self.call("send", hostID="different", requestID="r", text="do not send")
        self.assertEqual(self.bridge.store.history(self.cid)["messages"], [])

    async def test_duplicate_request_has_one_turn_and_preserves_text(self):
        text = "\n  literal text /path?x=1&y=2!\n"
        a = await self.call("send", requestID="r", text=text)
        b = await self.call("send", requestID="r", text=text)
        self.assertEqual(a["status"], b["status"])
        await asyncio.sleep(0)
        self.assertEqual(self.bridge.workers[self.cid].runs, [("r", text)])
        messages = self.bridge.store.history(self.cid)["messages"]
        self.assertEqual(len([x for x in messages if x["role"] == "user"]), 1)
        self.assertEqual(messages[0]["text"], text)

    async def test_request_cannot_change_payload_or_target(self):
        await self.call("send", requestID="r", text="first")
        with self.assertRaisesRegex(bridge.BridgeError, "cannot change"):
            await self.call("send", requestID="r", text="different")
        with self.assertRaisesRegex(bridge.BridgeError, "cannot change"):
            await self.call("send", conversation="other", requestID="r", text="first")

    async def test_busy_retains_second_message_off_host(self):
        await self.call("send", requestID="r", text="first")
        with self.assertRaisesRegex(bridge.BridgeError, "busy"):
            await self.call("send", requestID="second", text="second")
        self.assertEqual(self.bridge.store.db.execute("SELECT COUNT(*) FROM requests").fetchone()[0], 1)

    async def test_empty_oversized_and_nontext_rejected(self):
        for value in ("  \n", "x" * (bridge.MAX_TEXT + 1), None, {"text": "x"}):
            with self.assertRaises(bridge.BridgeError):
                await self.call("send", requestID="r", text=value)

    async def test_interrupt_is_bound_to_exact_request(self):
        await self.call("send", requestID="r", text="first")
        await asyncio.sleep(0)
        with self.assertRaisesRegex(bridge.BridgeError, "no longer active"):
            await self.call("interrupt", requestID="other-turn")
        self.assertFalse(self.bridge.workers[self.cid].interrupted)
        await self.call("interrupt", requestID="r")
        await self.bridge.tasks[self.cid]
        self.assertEqual((await self.call("receipt", requestID="r"))["status"], "interrupted")

    async def test_close_only_owns_new_bridge_conversation(self):
        with self.assertRaises(bridge.BridgeError):
            await self.call("close", conversation="history:native-session")
        await self.call("send", requestID="r", text="first")
        with self.assertRaises(bridge.BridgeError):
            await self.call("close")
        self.bridge.workers[self.cid].release.set()
        await self.bridge.tasks[self.cid]
        self.assertEqual((await self.call("close"))["status"], "closed")
        self.assertNotIn(self.cid, self.bridge.workers)
        self.assertEqual((await self.call("close"))["status"], "closed")
        self.assertEqual(len((await self.call("history"))["messages"]), 2)

    async def test_completion_reconciles_receipt_and_delta(self):
        await self.call("send", requestID="r", text="first")
        self.bridge.workers[self.cid].release.set()
        await self.bridge.tasks[self.cid]
        history = await self.call("history")
        self.assertEqual(history["status"], "ready")
        self.assertEqual(history["messages"][-1]["text"], "Hello world")
        self.assertEqual(len(history["messages"]), 2)
        self.assertEqual((await self.call("receipt", requestID="r"))["status"], "completed")

    async def test_interrupted_partial_output_is_not_left_streaming(self):
        worker = self.bridge.workers[self.cid]
        async def partial(rid, body):
            self.bridge.delta(self.cid, "partial", "unfinished reply")
            return "interrupted"
        worker.run = partial
        await self.call("send", requestID="r", text="interrupt fixture")
        await self.bridge.tasks[self.cid]
        message = (await self.call("history"))["messages"][-1]
        self.assertEqual(message["text"], "unfinished reply")
        self.assertEqual(message["status"], "interrupted")

    async def test_disconnected_partial_output_becomes_unknown_not_complete(self):
        worker = self.bridge.workers[self.cid]
        async def partial(rid, body):
            self.bridge.delta(self.cid, "partial", "unfinished reply")
            raise ConnectionError("fixture disconnect")
        worker.run = partial
        await self.call("send", requestID="r", text="disconnect fixture")
        await self.bridge.tasks[self.cid]
        rows = (await self.call("history"))["messages"]
        self.assertEqual(next(m for m in rows if m["role"] == "assistant")["status"], "unknown")
        self.assertFalse(any(m["status"] == "streaming" for m in rows))

    async def test_creation_is_idempotent_and_immutable(self):
        await self.call("create", requestID=self.cid, provider="codex", title="Fixture", cwd=str(self.home))
        self.assertEqual(len(self.bridge.workers), 1)
        with self.assertRaisesRegex(bridge.BridgeError, "already used"):
            await self.call("create", requestID=self.cid, provider="claude", title="Fixture", cwd=str(self.home))

    async def test_failed_worker_not_restarted_on_duplicate_create(self):
        class Failure(FakeWorker):
            async def open(self, cwd):
                raise bridge.BridgeError("Synthetic failure")
        self.bridge.factory["claude"] = Failure
        with self.assertRaises(bridge.BridgeError):
            await self.call("create", requestID="failed", provider="claude", title="Fixture", cwd=str(self.home))
        self.assertEqual((await self.call("create", requestID="failed", provider="claude", title="Fixture", cwd=str(self.home)))["id"], "failed")
        self.assertNotIn("failed", self.bridge.workers)

    async def test_restart_marks_inflight_unknown_and_never_replays(self):
        self.bridge.store.accept(self.cid, "r", "first")
        self.bridge.delta(self.cid, "unfinished", "partial answer")
        restarted = bridge.Bridge(self.state, self.home, {"codex": FakeWorker})
        try:
            self.assertEqual(restarted.workers, {})
            self.assertEqual(restarted.store.host_id, self.host)
            receipt = await restarted.dispatch("send", {"hostID": self.host, "conversation": self.cid, "requestID": "r", "text": "first"})
            self.assertEqual(receipt["status"], "unknown")
            self.assertEqual(restarted.store.history(self.cid)["messages"][-1]["status"], "unknown")
        finally:
            restarted.store.db.close()

    async def test_claude_permission_mode_is_explicit_and_startup_error_is_sanitized(self):
        seen = []
        class Client:
            def __init__(self, options):
                self.options = options
                seen.append(options)
            async def connect(self):
                self.options.stderr("Your organization requires remote managed settings to load, but they could not be loaded.")
                self.options.stderr("credential=NEVER-ECHO-THIS")
                raise RuntimeError("raw backend error with credential=NEVER-ECHO-THIS")
        sdk = types.ModuleType("claude_agent_sdk")
        sdk.ClaudeSDKClient = Client
        sdk.ClaudeAgentOptions = lambda **kwargs: types.SimpleNamespace(**kwargs)
        worker = bridge.ClaudeWorker(self.bridge, self.cid)
        with patch.dict(sys.modules, {"claude_agent_sdk": sdk}):
            with self.assertRaises(bridge.BridgeError) as error:
                await worker.initialize(str(self.home))
        self.assertEqual(seen[0].permission_mode, "default")
        self.assertEqual(seen[0].env["CLAUDE_BACKEND"], "login")
        self.assertTrue(all(seen[0].env[name] == "" for name in bridge.CLAUDE_ACCOUNT_CLEAR_ENV))
        self.assertIn("Sign Claude in again", str(error.exception))
        self.assertNotIn("NEVER-ECHO", str(error.exception))

    async def test_claude_interrupted_result_is_not_reported_as_success(self):
        sdk = types.ModuleType("claude_agent_sdk")
        sdk_types = types.ModuleType("claude_agent_sdk.types")
        for name in ("AssistantMessage", "SystemMessage", "TextBlock"):
            setattr(sdk, name, type(name, (), {}))
        sdk.ResultMessage = type("ResultMessage", (), {})
        sdk_types.StreamEvent = type("StreamEvent", (), {})
        class Client:
            reason = "completed"
            fail = False
            async def query(self, body):
                if self.fail: raise ConnectionError("query failed")
            async def receive_response(self):
                value = sdk.ResultMessage()
                value.terminal_reason, value.is_error = self.reason, False
                yield value
        worker = bridge.ClaudeWorker(self.bridge, self.cid)
        worker.client = Client()
        with patch.dict(sys.modules, {"claude_agent_sdk": sdk, "claude_agent_sdk.types": sdk_types}):
            for reason, expected in (("completed", "completed"), ("aborted_streaming", "interrupted"), ("aborted_tools", "interrupted")):
                worker.client.reason = reason
                self.assertEqual(await worker.query("r", "test"), expected)
                self.assertFalse(worker.active)
            worker.client.fail = True
            with self.assertRaises(ConnectionError): await worker.query("r", "test")
            self.assertFalse(worker.active)

    async def test_question_cannot_cross_conversations_and_expires(self):
        task = asyncio.create_task(self.bridge.permission(self.cid, "Bash", {"command": "printf test"}))
        await asyncio.sleep(0)
        qid = next(iter(self.bridge.questions))
        with self.assertRaises(bridge.BridgeError):
            await self.call("answer", conversation="other", questionID=qid, allow=True)
        await self.call("answer", questionID=qid, allow=False)
        self.assertFalse(await task)
        with self.assertRaises(bridge.BridgeError):
            await self.call("answer", questionID=qid, allow=True)

    async def test_oversized_approval_is_denied_not_truncated(self):
        self.assertFalse(await self.bridge.permission(self.cid, "Bash", {"command": "x" * 100000}))
        self.assertEqual(self.bridge.questions, {})

    async def test_history_paging_keeps_stable_ids(self):
        for i in range(250):
            self.bridge.store.message(self.cid, "m" + str(i), "assistant", "line " + str(i))
        latest = await self.call("history")
        older = await self.call("history", before=latest["before"])
        self.assertEqual(len(latest["messages"]), 100)
        self.assertEqual(len(older["messages"]), 100)
        self.assertTrue(set(x["id"] for x in latest["messages"]).isdisjoint(x["id"] for x in older["messages"]))

    async def test_output_limit_is_bytes_and_explicit(self):
        self.bridge.message(self.cid, "wide", "assistant", "\u4e2d" * 100000)
        value = (await self.call("history"))["messages"][0]
        self.assertLessEqual(len(value["text"].encode()), bridge.MAX_TEXT)
        self.assertEqual(value["status"], "truncated")
        self.assertIn("truncated", value["text"])

    async def test_native_discovery_is_readonly_and_does_not_change_files(self):
        folder = self.home / ".codex/sessions/2026/10/05"
        folder.mkdir(parents=True)
        path = folder / "fixture.jsonl"
        content = b'{"type":"session_meta","payload":{"cwd":"/fixture","id":"agent-id"}}\n' + b'{"type":"event_msg","payload":{"type":"user_message","message":"hello"}}\n'
        path.write_bytes(content)
        (self.home / ".codex/session_index.jsonl").write_text('{"id":"agent-id","thread_name":"The real session title"}\n')
        listing = await self.call("list")
        native = next(x for x in listing["conversations"] if x["id"].startswith("history:"))
        self.assertFalse(native["writable"])
        self.assertEqual(native["title"], "The real session title")
        history = await self.call("history", conversation=native["id"])
        self.assertEqual(history["messages"][0]["text"], "hello")
        with self.assertRaises(bridge.BridgeError):
            await self.call("send", conversation=native["id"], requestID="r", text="do not write")
        self.assertEqual(path.read_bytes(), content)

    async def test_discovery_rejects_symlink_replacement(self):
        folder = self.home / ".claude/projects/test"
        folder.mkdir(parents=True)
        path = folder / "fixture.jsonl"
        path.write_text('{"type":"user","message":{"content":"fixture"}}\n')
        cid = self.bridge.discovery.list()[0]["id"]
        other = self.home / "private.txt"
        other.write_text("must not be read")
        path.unlink(); path.symlink_to(other)
        with self.assertRaises(bridge.BridgeError):
            self.bridge.discovery.history(cid)

    async def test_unix_socket_disconnect_does_not_stop_agent(self):
        socket_path = str(Path(self.tmp.name) / "test.sock")
        server = await asyncio.start_unix_server(self.bridge.connection, path=socket_path, limit=bridge.MAX_FRAME)
        async with server:
            reader, writer = await asyncio.open_unix_connection(socket_path)
            async def rpc(method, params):
                writer.write(bridge.frame({"id": "wire", "method": method, "params": params}))
                await writer.drain()
                while True:
                    result = json.loads(await asyncio.wait_for(reader.readline(), 2))
                    if result.get("id") == "wire": return result
            hello = await rpc("hello", {})
            self.assertEqual(hello["result"]["hostID"], self.host)
            await rpc("send", {"hostID": self.host, "conversation": self.cid, "requestID": "r", "text": "first"})
            writer.close(); await writer.wait_closed()
            await asyncio.sleep(0.02)
            self.assertFalse(self.bridge.tasks[self.cid].done())
            self.bridge.workers[self.cid].release.set()
            await self.bridge.tasks[self.cid]
            self.assertEqual((await self.call("receipt", requestID="r"))["status"], "completed")

    async def test_handshake_required(self):
        socket_path = str(Path(self.tmp.name) / "test.sock")
        server = await asyncio.start_unix_server(self.bridge.connection, path=socket_path, limit=bridge.MAX_FRAME)
        async with server:
            reader, writer = await asyncio.open_unix_connection(socket_path)
            writer.write(bridge.frame({"id": "first", "method": "list", "params": {"hostID": self.host}}))
            await writer.drain()
            self.assertIn("Handshake required", json.loads(await reader.readline())["error"])
            writer.close(); await writer.wait_closed()

    async def test_half_close_flushes_final_receipt(self):
        socket_path = str(Path(self.tmp.name) / "half-close.sock")
        server = await asyncio.start_unix_server(self.bridge.connection, path=socket_path, limit=bridge.MAX_FRAME)
        async with server:
            reader, writer = await asyncio.open_unix_connection(socket_path)
            writer.write(bridge.frame({"id": "final", "method": "hello", "params": {}}))
            await writer.drain(); writer.write_eof()
            result = json.loads(await asyncio.wait_for(reader.readline(), 2))
            self.assertEqual(result["id"], "final")
            writer.close(); await writer.wait_closed()


class SecurityTests(unittest.TestCase):
    def test_installer_supports_python_without_ensurepip(self):
        spec = importlib.util.spec_from_file_location("installer", Path(__file__).parents[1] / "install-hermit-agent-bridge.py")
        installer = importlib.util.module_from_spec(spec); spec.loader.exec_module(installer)
        for available in (True, False):
            with self.subTest(ensurepip=available), patch.object(installer.subprocess, "run") as run:
                run.return_value.returncode = 0 if available else 1
                installer.install_environment("/python", Path("/private/venv"), Path("/requirements.txt"))
                commands = [call.args[0] for call in run.call_args_list]
                self.assertIn(["/python", "-m", "venv"] + ([] if available else ["--without-pip"]) + ["/private/venv"], commands)
                expected = ["/private/venv/bin/python", "-m", "pip"] if available else ["/python", "-m", "pip", "--python", "/private/venv/bin/python"]
                self.assertEqual(commands[-1], expected + ["install", "--disable-pip-version-check", "--no-cache-dir", "-r", "/requirements.txt"])

    def test_installer_without_ensurepip_or_targetable_pip_stops_before_writes(self):
        import subprocess
        spec = importlib.util.spec_from_file_location("installer", Path(__file__).parents[1] / "install-hermit-agent-bridge.py")
        installer = importlib.util.module_from_spec(spec); spec.loader.exec_module(installer)
        with patch.object(installer.subprocess, "run", side_effect=[types.SimpleNamespace(returncode=1), subprocess.CalledProcessError(1, "pip")]) as run:
            with self.assertRaises(subprocess.CalledProcessError):
                installer.install_environment("/python", Path("/private/venv"), Path("/requirements.txt"))
            self.assertEqual(run.call_count, 2)

    def test_claude_account_environment_overrides_inherited_provider_credentials(self):
        inherited = {name: "fixture-old-provider" for name in bridge.CLAUDE_ACCOUNT_CLEAR_ENV}
        inherited.update(HOME="/fixture/home", PATH="/fixture/bin", CLAUDE_BACKEND="ih",
                         CLAUDE_CONFIG_DIR="/fixture/claude", OPENAI_API_KEY="fixture-codex")
        with patch.dict(os.environ, inherited, clear=True):
            environment = bridge.claude_account_environment()
            effective = {**os.environ, **environment}
            self.assertTrue(all(effective[name] == "" for name in bridge.CLAUDE_ACCOUNT_CLEAR_ENV))
            self.assertEqual(effective["CLAUDE_BACKEND"], "login")
            self.assertEqual(environment["CLAUDE_CONFIG_DIR"], "/fixture/claude")
            self.assertEqual(os.environ["CLAUDE_BACKEND"], "ih")
            self.assertEqual(os.environ["ANTHROPIC_API_KEY"], "fixture-old-provider")
            self.assertEqual(bridge.child_environment()["OPENAI_API_KEY"], "fixture-codex")

    def test_claude_account_environment_without_inherited_overrides(self):
        with patch.dict(os.environ, {"HOME": "/fixture/home", "PATH": "/fixture/bin"}, clear=True):
            environment = bridge.claude_account_environment()
            self.assertEqual(environment["HOME"], "/fixture/home")
            self.assertEqual(environment["ANTHROPIC_API_KEY"], "")
            self.assertEqual(environment["ANTHROPIC_AUTH_TOKEN"], "")
            self.assertEqual(environment["ANTHROPIC_BASE_URL"], "")
            self.assertEqual(environment["CLAUDE_CODE_USE_BEDROCK"], "")
            self.assertEqual(environment["CLAUDE_BACKEND"], "login")

    def test_installer_renders_private_user_services(self):
        import plistlib
        installer_spec = importlib.util.spec_from_file_location("installer", Path(__file__).parents[1] / "install-hermit-agent-bridge.py")
        installer = importlib.util.module_from_spec(installer_spec); installer_spec.loader.exec_module(installer)
        home = Path("/tmp/test home")
        destination, data, path = installer.configuration(home, home / "python", home / "bridge.py", "darwin")
        config = plistlib.loads(data)
        self.assertEqual(config["ProgramArguments"], ["/tmp/test home/python", "/tmp/test home/bridge.py", "serve"])
        self.assertEqual(config["ThrottleInterval"], 60)
        self.assertIn("LaunchAgents", str(destination))
        destination, data, _ = installer.configuration(home, home / "python", home / "bridge.py", "linux")
        self.assertIn(b'ExecStart="/tmp/test home/python" "/tmp/test home/bridge.py" "serve"', data)
        self.assertIn(b"UMask=0077", data)
        self.assertIn("systemd/user", str(destination))
    def test_directory_permissions_fail_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "state"; path.mkdir(mode=0o755)
            os.chmod(path, 0o755)
            with self.assertRaises(bridge.BridgeError): bridge.Store(path)

    def test_frame_limit(self):
        with self.assertRaises(bridge.BridgeError): bridge.frame({"text": "x" * bridge.MAX_FRAME})


if __name__ == "__main__":
    unittest.main()
