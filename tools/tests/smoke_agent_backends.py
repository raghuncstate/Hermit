"""Exercise real CLI handshakes without credentials, prompts, tmux, or existing sessions."""
import asyncio
import os
from pathlib import Path
import tempfile
from unittest.mock import patch
from test_agent_bridge import bridge


async def main():
    with tempfile.TemporaryDirectory(prefix="hermit-backend-smoke-") as tmp:
        home = Path(tmp)
        (home / "codex").mkdir()
        (home / "claude").mkdir()
        environment = {key: value for key, value in os.environ.items() if key in ("PATH", "LANG", "TMPDIR")}
        environment.update({"HOME": str(home), "CODEX_HOME": str(home / "codex"), "CLAUDE_CONFIG_DIR": str(home / "claude"), "CLAUDECODE": ""})
        with patch.dict(os.environ, environment, clear=True):
            owner = bridge.Bridge(home / "state", home)
            for cid in ("codex-smoke", "claude-smoke"):
                owner.store.db.execute("INSERT INTO conversations VALUES(?,?,?,?,?,'starting',0,'test')", (cid, cid, cid.split('-')[0], str(home), ""))
            owner.store.db.commit()
            codex = bridge.CodexWorker(owner, "codex-smoke")
            try:
                codex.process = await asyncio.create_subprocess_exec("codex", "app-server", "--listen", "stdio://", stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL, env=bridge.child_environment(), limit=bridge.MAX_FRAME)
                codex.reader = asyncio.create_task(codex.read())
                initialized = await codex.rpc("initialize", {"clientInfo": {"name": "hermit-smoke", "version": "1"}})
                assert isinstance(initialized, dict)
                await codex.write({"method": "initialized", "params": {}})
                models = await codex.rpc("model/list", {})
                assert isinstance(models.get("data"), list)
                print("Codex initialize/model-list handshake passed; no thread or turn created")
            finally:
                await codex.close()
            claude = bridge.ClaudeWorker(owner, "claude-smoke")
            try:
                await asyncio.wait_for(claude.open(str(home)), 45)
                assert claude.client is not None
                print("Claude SDK persistent-client handshake passed; no prompt or resume issued")
            finally:
                await claude.close()
                owner.store.db.close()


if __name__ == "__main__":
    asyncio.run(main())
