#!/usr/bin/env python3
"""Private SSH/stdio relay for Hermit. Never attaches to, writes to, or kills tmux."""
import argparse
import asyncio
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import socket
import sqlite3
import stat
import struct
import sys
import time
import uuid

VERSION = 1
MAX_FRAME = 1024 * 1024
MAX_TEXT = 128 * 1024
MAX_HISTORY = 700 * 1024
CLAUDE_ACCOUNT_CLEAR_ENV = (
    "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL",
    "ANTHROPIC_MODEL", "ANTHROPIC_SMALL_FAST_MODEL",
    "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL", "CLAUDE_CODE_OAUTH_TOKEN",
    "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
    "CLAUDE_CODE_USE_AWS",
)


class BridgeError(Exception):
    pass


def text(value, limit=MAX_TEXT):
    if not isinstance(value, str) or len(value.encode()) > limit:
        raise BridgeError("Invalid or oversized text")
    return value


def frame(value):
    result = json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode() + b"\n"
    if len(result) > MAX_FRAME:
        raise BridgeError("Response exceeds protocol limit")
    return result


def bounded_output(body):
    raw = str(body).encode()
    if len(raw) <= MAX_TEXT:
        return str(body), False
    return raw[:MAX_TEXT - 160].decode("utf-8", errors="ignore") + "\n[Output truncated at 128 KiB; inspect the host transcript for the remainder.]", True


def transcript_file(path, root):
    if path.is_symlink() or not path.resolve().is_relative_to(root.resolve()):
        raise BridgeError("Transcript path changed")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    s = os.fstat(fd)
    if not stat.S_ISREG(s.st_mode) or s.st_uid != os.getuid():
        os.close(fd)
        raise BridgeError("Untrusted transcript")
    return os.fdopen(fd, "rb")


def child_environment():
    names = {"HOME", "PATH", "LANG", "LC_ALL", "TMPDIR", "USER", "LOGNAME",
             "CODEX_HOME", "CLAUDE_CONFIG_DIR", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN",
             "ANTHROPIC_BASE_URL", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX",
             "AWS_PROFILE", "AWS_REGION", "GOOGLE_CLOUD_PROJECT", "OPENAI_API_KEY"}
    return {k: v for k, v in os.environ.items() if k in names}


def claude_account_environment():
    environment = child_environment()
    # The SDK merges env into the parent environment; omission does not clear IH.
    environment.update({name: "" for name in CLAUDE_ACCOUNT_CLEAR_ENV})
    environment["CLAUDE_BACKEND"] = "login"
    return environment


def private_directory(path):
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    s = path.lstat()
    if not stat.S_ISDIR(s.st_mode) or s.st_uid != os.getuid() or s.st_mode & 0o077:
        raise BridgeError("Bridge directory must be owned by this user with mode 0700")


class Store:
    def __init__(self, directory):
        private_directory(directory)
        db_path = directory / "bridge.sqlite3"
        if db_path.is_symlink():
            raise BridgeError("Refusing symlink database")
        self.db = sqlite3.connect(db_path)
        os.chmod(db_path, 0o600)
        self.db.row_factory = sqlite3.Row
        self.db.executescript("""
          PRAGMA journal_mode=WAL;
          PRAGMA synchronous=FULL;
          CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
          CREATE TABLE IF NOT EXISTS conversations
            (id TEXT PRIMARY KEY, title TEXT, provider TEXT, cwd TEXT, backend TEXT,
             status TEXT, updated REAL, creation_hash TEXT);
          CREATE TABLE IF NOT EXISTS messages
            (seq INTEGER PRIMARY KEY AUTOINCREMENT, conversation TEXT, id TEXT UNIQUE,
             role TEXT, text TEXT, status TEXT);
          CREATE TABLE IF NOT EXISTS requests
            (id TEXT PRIMARY KEY, conversation TEXT, hash TEXT, status TEXT, turn TEXT);
        """)
        self.db.execute("INSERT OR IGNORE INTO metadata VALUES ('host', ?)", (str(uuid.uuid4()),))
        self.db.execute("UPDATE requests SET status='unknown' WHERE status IN ('accepted','working')")
        self.db.execute("UPDATE messages SET status='unknown' WHERE status='streaming'")
        self.db.execute("UPDATE conversations SET status='offline'")
        self.db.commit()
        self.host_id = self.db.execute("SELECT value FROM metadata WHERE key='host'").fetchone()[0]

    def conversations(self):
        return [dict(x) for x in self.db.execute("SELECT * FROM conversations ORDER BY updated DESC LIMIT 500")]

    def get(self, cid):
        row = self.db.execute("SELECT * FROM conversations WHERE id=?", (cid,)).fetchone()
        if row is None:
            raise BridgeError("Conversation not found")
        return dict(row)

    def message(self, cid, mid, role, body, status="complete"):
        # Message size is bounded even if a backend emits unlimited output.
        body, clipped = bounded_output(body)
        if clipped:
            status = "truncated"
        self.db.execute("INSERT INTO messages(conversation,id,role,text,status) VALUES(?,?,?,?,?) "
                        "ON CONFLICT(id) DO UPDATE SET text=excluded.text,status=excluded.status",
                        (cid, mid, role, body, status))
        self.db.commit()

    def state(self, cid, status):
        self.db.execute("UPDATE conversations SET status=?,updated=? WHERE id=?", (status, time.time(), cid))
        self.db.commit()

    def finish_streams(self, cid, status):
        self.db.execute("UPDATE messages SET status=? WHERE conversation=? AND status='streaming'",
                        ("complete" if status == "completed" else status, cid))
        self.db.commit()

    def history(self, cid, before=None):
        rows = self.db.execute("SELECT * FROM messages WHERE conversation=? AND seq<? ORDER BY seq DESC LIMIT 100",
                               (cid, before or 2**63 - 1)).fetchall()
        result, size = [], 0
        for row in rows:
            item = dict(row)
            size += len(frame(item))
            if size > MAX_HISTORY:
                break
            result.append(item)
        result.reverse()
        oldest = result[0]["seq"] if result else None
        more = bool(oldest and self.db.execute("SELECT 1 FROM messages WHERE conversation=? AND seq<? LIMIT 1", (cid, oldest)).fetchone())
        return {"messages": result, "before": oldest if more else None, "partial": False}

    def accept(self, cid, rid, body):
        digest = hashlib.sha256(body.encode()).hexdigest()
        row = self.db.execute("SELECT * FROM requests WHERE id=?", (rid,)).fetchone()
        if row:
            if row["conversation"] != cid or row["hash"] != digest:
                raise BridgeError("Request ID cannot change target or content")
            return dict(row), False
        with self.db:
            self.db.execute("INSERT INTO requests VALUES(?,?,?,'accepted',NULL)", (rid, cid, digest))
            self.db.execute("INSERT INTO messages(conversation,id,role,text,status) VALUES(?,?,? ,?,'complete')",
                            (cid, rid, "user", body))
        return {"id": rid, "status": "accepted"}, True


class Discovery:
    """Bounded, read-only native transcript discovery. IDs are path-scoped, never guessed."""
    def __init__(self, home):
        self.home = home.resolve()
        self.paths = {}

    def roots(self):
        return [("codex", self.home / ".codex/sessions"), ("claude", self.home / ".claude/projects")]

    def list(self):
        entries = []
        new_paths = {}
        names = {}
        index = self.home / ".codex/session_index.jsonl"
        if index.is_file():
            try:
                with transcript_file(index, self.home / ".codex") as source:
                    size = os.fstat(source.fileno()).st_size
                    if size > 4 * 1024 * 1024:
                        source.seek(size - 4 * 1024 * 1024); source.readline(MAX_FRAME)
                    for line in source:
                        if len(line) > MAX_FRAME: continue
                        record = json.loads(line)
                        if isinstance(record.get("id"), str) and isinstance(record.get("thread_name"), str):
                            names[record["id"]] = record["thread_name"]
            except (OSError, ValueError, BridgeError):
                pass
        for provider, root in self.roots():
            if not root.is_dir() or root.is_symlink():
                continue
            paths = []
            for index, path in enumerate(root.rglob("*.jsonl")):
                if index >= 20000:
                    break
                if path.is_symlink() or not path.resolve().is_relative_to(root.resolve()):
                    continue
                try:
                    if path.is_file(): paths.append((path.stat().st_mtime, path))
                except OSError:
                    continue
            paths.sort(key=lambda item: item[0], reverse=True)
            for _, path in paths[:80]:
                try:
                    cid = "history:" + hashlib.sha256(str(path).encode()).hexdigest()
                    cwd, title, backend = "", path.stem[-12:], ""
                    with transcript_file(path, root) as source:
                        for _ in range(20):
                            line = source.readline(MAX_FRAME + 1)
                            if not line or len(line) > MAX_FRAME:
                                break
                            record = json.loads(line)
                            meta = record.get("payload", {}) if provider == "codex" else record
                            if isinstance(meta, dict):
                                cwd = meta.get("cwd", cwd)
                                title = meta.get("title") or meta.get("customTitle") or title
                                if provider == "codex" and record.get("type") == "session_meta": backend = meta.get("id", "")
                                elif provider == "claude": backend = record.get("sessionId", backend)
                        if provider == "claude":
                            source.seek(max(0, path.stat().st_size - 65536))
                            if source.tell(): source.readline(MAX_FRAME)
                            for line in source:
                                try:
                                    value = json.loads(line)
                                    if value.get("type") == "custom-title" and isinstance(value.get("customTitle"), str): title = value["customTitle"]
                                except (ValueError, AttributeError): pass
                    title = names.get(backend, title)
                    new_paths[cid] = (path, root, provider)
                    entries.append({"id": cid, "provider": provider, "title": str(title), "cwd": str(cwd),
                                    "backend": backend, "status": "history", "writable": False, "updated": path.stat().st_mtime})
                except (OSError, ValueError, TypeError, BridgeError):
                    continue
        self.paths = new_paths
        return sorted(entries, key=lambda x: x["updated"], reverse=True)[:160]

    def history(self, cid, before=None):
        source_info = self.paths.get(cid)
        if source_info is None:
            raise BridgeError("Refresh conversations before opening this history")
        path, root, provider = source_info
        if path.is_symlink() or not path.resolve().is_relative_to(root.resolve()):
            raise BridgeError("Transcript path changed")
        messages = []
        # Byte cursor reads older pages without copying or modifying the agent's databases.
        with transcript_file(path, root) as source:
            size = os.fstat(source.fileno()).st_size
            end = min(before if before is not None else size, size)
            start = max(0, end - 512 * 1024)
            source.seek(start)
            if start:
                source.readline(MAX_FRAME + 1)
            valid_start = source.tell()
            while source.tell() < end:
                offset = source.tell()
                line = source.readline(MAX_FRAME + 1)
                if not line or len(line) > MAX_FRAME:
                    break
                try:
                    record = json.loads(line)
                    payload = record.get("payload", {})
                    role, body = None, None
                    if provider == "codex" and record.get("type") == "event_msg":
                        kind = payload.get("type")
                        if kind in ("user_message", "agent_message"):
                            role = "user" if kind == "user_message" else "assistant"
                            body = payload.get("message")
                    elif provider == "claude" and record.get("type") in ("user", "assistant"):
                        role = record["type"]
                        content = record.get("message", {}).get("content", [])
                        body = content if isinstance(content, str) else "\n".join(
                            x["text"] for x in content if isinstance(x, dict) and x.get("type") == "text" and isinstance(x.get("text"), str))
                    if role and isinstance(body, str) and body:
                        body, clipped = bounded_output(body)
                        messages.append({"id": f"{cid}:{offset}", "role": role, "text": body, "status": "truncated" if clipped else "complete", "seq": offset})
                except (ValueError, TypeError, AttributeError):
                    continue
        trimmed = False
        while messages and len(json.dumps(messages, ensure_ascii=False).encode()) > MAX_HISTORY:
            messages.pop(0)
            trimmed = True
        cursor = messages[0]["seq"] if trimmed and messages else valid_start if start else None
        return {"messages": messages, "before": cursor, "partial": True}


class CodexWorker:
    def __init__(self, bridge, cid):
        self.bridge, self.cid = bridge, cid
        self.process = None
        self.pending, self.counter, self.turn = {}, 0, None
        self.reader = None
        self.done = None

    async def open(self, cwd):
        self.process = await asyncio.create_subprocess_exec(
            "codex", "app-server", "--listen", "stdio://",
            stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL, env=child_environment(), limit=MAX_FRAME)
        self.reader = asyncio.create_task(self.read())
        await self.rpc("initialize", {"clientInfo": {"name": "hermit", "title": "Hermit", "version": "1"}})
        await self.write({"method": "initialized", "params": {}})
        models, cursor = [], None
        for _ in range(10):
            page = await self.rpc("model/list", {"cursor": cursor} if cursor else {})
            models.extend(page.get("data", []))
            cursor = page.get("nextCursor")
            if not cursor: break
        available = {m.get("model", m.get("id")) for m in models}
        model, effort = next(((m, r) for m, r in (("gpt-6-astra", "max"), ("gpt-5.6-sol", "ultra")) if m in available), (None, None))
        if not model:
            raise BridgeError("Neither configured Codex model is available; no agent was started")
        selected = next(m for m in models if m.get("model", m.get("id")) == model)
        if effort not in {r.get("reasoningEffort") for r in selected.get("supportedReasoningEfforts", [])}:
            raise BridgeError("Configured reasoning effort is unavailable for this Codex model")
        self.effort = effort
        result = await self.rpc("thread/start", {"cwd": cwd, "model": model, "approvalPolicy": "never", "sandbox": "danger-full-access"})
        self.backend_id = result["thread"]["id"]
        return self.backend_id

    async def write(self, value):
        self.process.stdin.write(frame(value))
        await self.process.stdin.drain()

    async def rpc(self, method, params):
        self.counter += 1
        rid = self.counter
        future = asyncio.get_running_loop().create_future()
        self.pending[rid] = future
        try:
            await self.write({"id": rid, "method": method, "params": params})
            return await asyncio.wait_for(future, 30)
        finally:
            self.pending.pop(rid, None)

    async def read(self):
        try:
            while line := await self.process.stdout.readline():
                if len(line) > MAX_FRAME:
                    raise BridgeError("Backend frame too large")
                item = json.loads(line)
                if "id" in item and "method" not in item:
                    future = self.pending.get(item["id"])
                    if future and not future.done():
                        if "error" in item:
                            future.set_exception(BridgeError("Codex rejected the operation; check account and CLI compatibility"))
                        else:
                            future.set_result(item.get("result", {}))
                    continue
                if "id" in item:
                    # Never auto-approve an unrecognized server request.
                    await self.write({"id": item["id"], "error": {"code": -32601, "message": "Unsupported interactive request in Hermit bridge"}})
                    self.bridge.message(self.cid, str(uuid.uuid4()), "notice", "Codex requested an unsupported interaction. The request was not approved.")
                    continue
                params = item.get("params", {})
                method = item.get("method")
                if params.get("threadId") and hasattr(self, "backend_id") and params["threadId"] != self.backend_id:
                    continue
                if method == "item/agentMessage/delta":
                    self.bridge.delta(self.cid, params.get("itemId", "response"), params.get("delta", ""))
                elif method == "item/completed":
                    value = params.get("item", {})
                    if value.get("type") == "agentMessage":
                        self.bridge.message(self.cid, value["id"], "assistant", value.get("text", ""))
                elif method == "item/started":
                    value = params.get("item", {})
                    if value.get("type") in ("commandExecution", "fileChange", "mcpToolCall"):
                        self.bridge.message(self.cid, value["id"], "tool", value.get("command") or value.get("tool") or value["type"])
                elif method == "turn/completed" and self.done and not self.done.done():
                    self.done.set_result(params.get("turn", {}).get("status", "unknown"))
        except (Exception, asyncio.CancelledError):
            pass
        finally:
            self.bridge.store.state(self.cid, "offline")
            self.bridge.changed(self.cid)
            for future in list(self.pending.values()):
                if not future.done():
                    future.set_exception(BridgeError("Codex connection ended"))
            if self.done and not self.done.done():
                self.done.set_exception(BridgeError("Codex connection ended; delivery unknown"))

    async def run(self, rid, body):
        self.done = asyncio.get_running_loop().create_future()
        result = await self.rpc("turn/start", {"threadId": self.backend_id, "input": [{"type": "text", "text": body}], "effort": self.effort})
        self.turn = result["turn"]["id"]
        self.bridge.store.db.execute("UPDATE requests SET turn=? WHERE id=?", (self.turn, rid))
        self.bridge.store.db.commit()
        return await self.done

    async def interrupt(self):
        if not self.turn or not self.done or self.done.done():
            raise BridgeError("No active turn to interrupt")
        await self.rpc("turn/interrupt", {"threadId": self.backend_id, "turnId": self.turn})

    async def close(self):
        if self.process and self.process.returncode is None:
            self.process.terminate()
            try:
                await asyncio.wait_for(self.process.wait(), 5)
            except asyncio.TimeoutError:
                self.process.kill()
                await self.process.wait()
        if self.reader:
            self.reader.cancel()


class ClaudeWorker:
    def __init__(self, bridge, cid):
        self.bridge, self.cid, self.client = bridge, cid, None
        self.active = False
        self.jobs = asyncio.Queue()
        self.actor = None
        self.startup_failure = None

    def backend_stderr(self, line):
        # Report only recognized diagnostics, never raw stderr or credential-bearing URLs.
        if "organization requires remote managed settings to load" in line.lower():
            self.startup_failure = "Claude could not load required organization settings. Sign Claude in again on this host or check its organization/network access. No message was sent."

    async def open(self, cwd):
        ready = asyncio.get_running_loop().create_future()
        self.actor = asyncio.create_task(self.operate(cwd, ready))
        return await ready

    async def operate(self, cwd, ready):
        # The SDK's AnyIO lifetime and all queries remain in one owning task.
        try:
            await self.initialize(cwd)
            ready.set_result("")
            while True:
                job = await self.jobs.get()
                if job is None:
                    break
                rid, body, result = job
                try:
                    result.set_result(await self.query(rid, body))
                except Exception as error:
                    if not result.done():
                        result.set_exception(error)
        except BaseException as error:
            if not ready.done():
                ready.set_exception(error)
        finally:
            if self.client:
                await self.client.disconnect()

    async def initialize(self, cwd):
        try:
            from claude_agent_sdk import ClaudeSDKClient, ClaudeAgentOptions
        except ImportError as error:
            raise BridgeError("Claude Agent SDK is not installed in the bridge environment") from error
        async def can_use_tool(name, input_data, context):
            from claude_agent_sdk import PermissionResultAllow, PermissionResultDeny
            if name == "AskUserQuestion":
                self.bridge.message(self.cid, str(uuid.uuid4()), "notice", "Structured multiple-choice questions are not supported yet. Ask the agent to ask in plain text.")
                return PermissionResultDeny(message="Ask the user in plain text instead")
            approved = await self.bridge.permission(self.cid, name, input_data)
            return PermissionResultAllow(updated_input=input_data) if approved else PermissionResultDeny(message="Not approved in Hermit")
        self.client = ClaudeSDKClient(ClaudeAgentOptions(
            cwd=cwd, include_partial_messages=True, setting_sources=["user", "project", "local"],
            permission_mode="default", can_use_tool=can_use_tool, env=claude_account_environment(), stderr=self.backend_stderr))
        try:
            await self.client.connect()
        except Exception as error:
            if self.startup_failure:
                raise BridgeError(self.startup_failure) from error
            raise
        return ""

    async def run(self, rid, body):
        result = asyncio.get_running_loop().create_future()
        await self.jobs.put((rid, body, result))
        return await result

    async def query(self, rid, body):
        from claude_agent_sdk import AssistantMessage, ResultMessage, SystemMessage, TextBlock
        from claude_agent_sdk.types import StreamEvent
        self.active = True
        mid, content = str(uuid.uuid4()), ""
        try:
            await self.client.query(body)
            async for value in self.client.receive_response():
                if isinstance(value, SystemMessage) and value.subtype == "init":
                    self.bridge.store.db.execute("UPDATE conversations SET backend=? WHERE id=?", (value.data.get("session_id", ""), self.cid))
                    self.bridge.store.db.commit()
                elif isinstance(value, StreamEvent):
                    event = value.event
                    if event.get("type") == "message_start":
                        mid, content = str(uuid.uuid4()), ""
                    if event.get("type") == "content_block_delta" and event.get("delta", {}).get("type") == "text_delta":
                        content, _ = bounded_output(content + event["delta"].get("text", ""))
                        self.bridge.message(self.cid, mid, "assistant", content, "streaming")
                elif isinstance(value, AssistantMessage):
                    body_text = "\n".join(block.text for block in value.content if isinstance(block, TextBlock))
                    if body_text:
                        self.bridge.message(self.cid, mid, "assistant", body_text)
                    mid, content = str(uuid.uuid4()), ""
                elif isinstance(value, ResultMessage):
                    if getattr(value, "terminal_reason", None) in ("aborted_streaming", "aborted_tools"):
                        return "interrupted"
                    return "failed" if value.is_error else "completed"
            return "unknown"
        finally:
            self.active = False

    async def interrupt(self):
        if not self.active:
            raise BridgeError("No active turn to interrupt")
        await self.client.interrupt()

    async def close(self):
        if self.actor and not self.actor.done():
            if self.active:
                with contextlib.suppress(Exception):
                    await self.interrupt()
            await self.jobs.put(None)
            try:
                await asyncio.wait_for(self.actor, 5)
            except (Exception, asyncio.CancelledError):
                pass


class Bridge:
    def __init__(self, directory, home=None, worker_factory=None):
        self.store = Store(directory)
        self.discovery = Discovery(home or Path.home())
        self.workers, self.tasks, self.clients, self.questions = {}, {}, {}, {}
        self.epoch, self.sequence = str(uuid.uuid4()), 0
        self.factory = worker_factory or {"codex": CodexWorker, "claude": ClaudeWorker}

    def changed(self, cid):
        self.sequence += 1
        event = {"method": "changed", "epoch": self.epoch, "sequence": self.sequence, "conversation": cid}
        for queue, writer in tuple(self.clients.items()):
            if queue.full():
                # Never discard an RPC receipt to make room for notifications.
                writer.close()
            else:
                queue.put_nowait(event)

    def message(self, cid, mid, role, body, status="complete"):
        self.store.message(cid, cid + ":" + mid, role, body, status)
        self.changed(cid)

    def delta(self, cid, mid, value):
        row = self.store.db.execute("SELECT text FROM messages WHERE id=?", (cid + ":" + mid,)).fetchone()
        self.message(cid, mid, "assistant", (row[0] if row else "") + value, "streaming")

    async def permission(self, cid, name, input_data):
        detail = json.dumps(input_data, ensure_ascii=False)
        if len(detail.encode()) > 64 * 1024:
            self.message(cid, str(uuid.uuid4()), "notice", "A tool requested approval with oversized arguments. It was denied, not shown incompletely.")
            return False
        qid = str(uuid.uuid4())
        future = asyncio.get_running_loop().create_future()
        self.questions[qid] = (cid, future, name, detail)
        self.store.state(cid, "needsInput")
        self.changed(cid)
        try:
            return await asyncio.wait_for(future, 300)
        except asyncio.TimeoutError:
            return False
        finally:
            self.questions.pop(qid, None)
            self.store.state(cid, "working")
            self.changed(cid)

    def descriptors(self):
        result = self.store.conversations()
        for item in result:
            item["writable"] = item["id"] in self.workers and item["status"] not in ("unknown", "offline", "failed")
        return result

    async def dispatch(self, method, params):
        if method == "hello":
            return {"version": VERSION, "hostID": self.store.host_id, "epoch": self.epoch,
                    "namespace": f"{os.getuid()}:{self.discovery.home}", "sequence": self.sequence}
        if params.get("hostID") != self.store.host_id:
            raise BridgeError("Host identity changed; reconnect and verify the destination")
        if method == "ping":
            return {"sequence": self.sequence}
        if method == "list":
            native = await asyncio.to_thread(self.discovery.list) if params.get("discover", True) else []
            managed = self.descriptors()
            owned = {(x["provider"], x["backend"]) for x in managed if x["backend"]}
            return {"conversations": managed + [x for x in native if (x["provider"], x.get("backend")) not in owned], "complete": False}
        if method == "create":
            cid, provider = text(params.get("requestID"), 100), params.get("provider")
            title, cwd = text(params.get("title"), 200), text(params.get("cwd"), 4096)
            if provider not in self.factory or not title.strip() or not Path(cwd).is_absolute() or not Path(cwd).is_dir():
                raise BridgeError("Choose a supported agent, title, and existing absolute project directory")
            digest = hashlib.sha256(frame([provider, title, cwd])).hexdigest()
            row = self.store.db.execute("SELECT creation_hash FROM conversations WHERE id=?", (cid,)).fetchone()
            if row:
                if row[0] != digest:
                    raise BridgeError("Creation request ID already used")
                return {"id": cid}
            if len(self.workers) >= 8:
                raise BridgeError("Eight bridge-owned conversations are already open")
            self.store.db.execute("INSERT INTO conversations VALUES(?,?,?,?,?,'starting',?,?)", (cid, title, provider, cwd, "", time.time(), digest))
            self.store.db.commit()
            worker = self.factory[provider](self, cid)
            try:
                backend = await worker.open(cwd)
                self.store.db.execute("UPDATE conversations SET backend=?,status='ready' WHERE id=?", (backend, cid))
                self.store.db.commit()
                self.workers[cid] = worker
            except BaseException:
                await worker.close()
                self.store.state(cid, "failed")
                raise
            self.changed(cid)
            return {"id": cid}
        cid = text(params.get("conversation"), 200)
        if method == "history":
            before = params.get("before")
            if before is not None and (not isinstance(before, int) or before < 0):
                raise BridgeError("Invalid history cursor")
            if cid.startswith("history:"):
                return await asyncio.to_thread(self.discovery.history, cid, before)
            self.store.get(cid)
            result = self.store.history(cid, before)
            result["question"] = next(({"id": k, "title": q[2], "detail": q[3]} for k, q in self.questions.items() if q[0] == cid), None)
            result["status"] = self.store.get(cid)["status"]
            result["requestID"] = next((r[0] for r in self.store.db.execute("SELECT id FROM requests WHERE conversation=? AND status='working'", (cid,))), None)
            return result
        if method == "receipt":
            row = self.store.db.execute("SELECT id,status,turn FROM requests WHERE id=? AND conversation=?", (text(params.get("requestID"), 100), cid)).fetchone()
            return dict(row) if row else {"status": "unknown"}
        if method == "send":
            body, rid = text(params.get("text")), text(params.get("requestID"), 100)
            if not body.strip():
                raise BridgeError("Message is empty")
            # Return old receipts even when the original worker no longer exists.
            existing = self.store.db.execute("SELECT 1 FROM requests WHERE id=?", (rid,)).fetchone()
            if existing:
                return self.store.accept(cid, rid, body)[0]
            if cid not in self.workers or self.store.get(cid)["status"] in ("unknown", "offline", "failed"):
                raise BridgeError("Read-only conversation; existing agents are never resumed or sent tmux keys")
            if cid in self.tasks and not self.tasks[cid].done():
                raise BridgeError("Agent is busy; retain this message as a draft")
            receipt, _ = self.store.accept(cid, rid, body)
            self.store.state(cid, "working")
            self.tasks[cid] = asyncio.create_task(self.run(cid, rid, body))
            return receipt
        if method == "interrupt":
            row = self.store.db.execute("SELECT status FROM requests WHERE conversation=? AND id=?", (cid, text(params.get("requestID"), 100))).fetchone()
            if not row or row[0] != "working" or cid not in self.workers:
                raise BridgeError("That turn is no longer active")
            for question in tuple(self.questions.values()):
                if question[0] == cid and not question[1].done(): question[1].set_result(False)
            await self.workers[cid].interrupt()
            return {"status": "interruptRequested"}
        if method == "close":
            self.store.get(cid)
            if cid in self.tasks and not self.tasks[cid].done():
                raise BridgeError("Interrupt the active turn before ending this conversation")
            worker = self.workers.pop(cid, None)
            if worker:
                await worker.close()
            self.store.state(cid, "closed")
            self.changed(cid)
            return {"status": "closed"}
        if method == "answer":
            qid = text(params.get("questionID"), 100)
            question = self.questions.get(qid)
            if not question or question[0] != cid or question[1].done() or not isinstance(params.get("allow"), bool):
                raise BridgeError("Question expired or belongs to another conversation")
            question[1].set_result(params["allow"])
            return {"status": "answered"}
        raise BridgeError("Unsupported operation")

    async def run(self, cid, rid, body):
        self.store.db.execute("UPDATE requests SET status='working' WHERE id=?", (rid,))
        self.store.db.commit()
        self.changed(cid)
        try:
            status = await self.workers[cid].run(rid, body)
            if status not in ("completed", "failed", "interrupted"):
                status = "unknown"
        except (Exception, asyncio.CancelledError):
            status = "unknown"
            self.message(cid, str(uuid.uuid4()), "notice", "The agent connection ended. Delivery is uncertain; the message will not be resent.")
        self.store.db.execute("UPDATE requests SET status=? WHERE id=?", (status, rid))
        self.store.db.commit()
        self.store.finish_streams(cid, status)
        if status == "failed":
            self.message(cid, str(uuid.uuid4()), "notice", "The agent reported a failed turn. Nothing was resent.")
        self.store.state(cid, "ready" if status in ("completed", "interrupted", "failed") else status)
        self.changed(cid)

    async def connection(self, reader, writer):
        sock = writer.get_extra_info("socket")
        if hasattr(sock, "getpeereid"):
            trusted = sock.getpeereid()[0] == os.getuid()
        elif sys.platform.startswith("linux"):
            trusted = struct.unpack("3i", sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))[1] == os.getuid()
        else:
            trusted = True  # macOS also enforces the 0600 socket and 0700 parent.
        if not trusted:
            writer.close()
            return
        queue = asyncio.Queue(maxsize=64)
        self.clients[queue] = writer
        async def output():
            try:
                while True:
                    item = await queue.get()
                    try:
                        writer.write(frame(item))
                        await asyncio.wait_for(writer.drain(), 15)
                    finally:
                        queue.task_done()
            finally:
                writer.close()
        sender = asyncio.create_task(output())
        initialized = False
        try:
            while line := await reader.readline():
                if len(line) > MAX_FRAME:
                    break
                request = json.loads(line)
                rid = request.get("id")
                if not isinstance(rid, str) or len(rid) > 100 or not isinstance(request.get("params", {}), dict):
                    break
                try:
                    method = request.get("method")
                    if not initialized and method != "hello":
                        raise BridgeError("Handshake required")
                    result = await self.dispatch(method, request.get("params", {}))
                    initialized = True
                    await queue.put({"id": rid, "result": result})
                except BridgeError as error:
                    await queue.put({"id": rid, "error": str(error), "rejected": True})
                except Exception:
                    await queue.put({"id": rid, "error": "Bridge operation failed; no automatic retry was performed"})
        except (ValueError, OSError, AttributeError, asyncio.CancelledError):
            pass
        finally:
            self.clients.pop(queue, None)
            if not writer.is_closing():
                with contextlib.suppress(Exception):
                    await asyncio.wait_for(queue.join(), 2)
            sender.cancel()
            with contextlib.suppress(Exception, asyncio.CancelledError):
                await sender
            writer.close()
            with contextlib.suppress(Exception):
                await writer.wait_closed()


async def serve(directory, home):
    private_directory(directory)
    lock = os.open(directory / "service.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    path = directory / "bridge.sock"
    if path.exists():
        if not stat.S_ISSOCK(path.lstat().st_mode):
            raise BridgeError("Socket path is occupied by a non-socket")
        path.unlink()
    bridge = Bridge(directory, home)
    server = await asyncio.start_unix_server(bridge.connection, path=str(path), limit=MAX_FRAME)
    os.chmod(path, 0o600)
    async with server:
        try:
            await server.serve_forever()
        finally:
            for worker in bridge.workers.values():
                await worker.close()
            os.close(lock)


async def connect(directory):
    private_directory(directory)
    path = directory / "bridge.sock"
    s = path.lstat()
    if not stat.S_ISSOCK(s.st_mode) or s.st_uid != os.getuid() or s.st_mode & 0o077:
        raise BridgeError("Untrusted bridge socket")
    reader, writer = await asyncio.open_unix_connection(str(path), limit=MAX_FRAME)
    async def send():
        source = asyncio.StreamReader(limit=MAX_FRAME)
        await asyncio.get_running_loop().connect_read_pipe(lambda: asyncio.StreamReaderProtocol(source), sys.stdin.buffer)
        while line := await source.readline():
            if len(line) > MAX_FRAME:
                raise BridgeError("Frame too large")
            writer.write(line)
            await writer.drain()
        writer.write_eof()
    async def receive():
        while line := await reader.readline():
            sys.stdout.buffer.write(line)
            sys.stdout.buffer.flush()
    tasks = [asyncio.create_task(send()), asyncio.create_task(receive())]
    try:
        done, _ = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        for task in done:
            task.result()
        if tasks[0] in done and tasks[1] not in done:
            await asyncio.wait_for(tasks[1], 5)
    finally:
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        writer.close()
        await writer.wait_closed()


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("serve", "connect"))
    parser.add_argument("--state", type=Path, default=Path.home() / ".local/state/hermit-agent-bridge")
    parser.add_argument("--home", type=Path, default=Path.home(), help="Transcript home; server only")
    args = parser.parse_args()
    try:
        asyncio.run(serve(args.state, args.home) if args.command == "serve" else connect(args.state))
    except KeyboardInterrupt:
        pass
    except Exception:
        print("Hermit bridge unavailable. Check the private service installation and permissions.", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
