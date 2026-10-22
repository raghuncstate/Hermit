"""Forced command for a disposable loopback sshd; never executes caller text."""
import json
import os
from pathlib import Path
import selectors
import shlex
import subprocess
import sys

CONTROL_DRAIN_SCRIPT = '"$@" | { trap \'\' PIPE; /bin/cat 2>/dev/null || /bin/cat >/dev/null; }'


def control_argv(tmux, socket, session):
    return ["/bin/sh", "-c", CONTROL_DRAIN_SCRIPT, "hermit-control", tmux, "-L", socket,
            "-C", "new-session", "-A", "-f", "ignore-size", "-s", session]


def main():
    fixture = json.loads(Path(sys.argv[1]).read_text())
    assert fixture["socket"].startswith("hermit-control-test-")
    requested = shlex.split(os.environ.get("SSH_ORIGINAL_COMMAND", ""))
    prefix = ["exec"] + control_argv(fixture["tmux"], fixture["socket"], "fixture")[:-1]
    if requested[:-1] != prefix or requested[-1:] not in [["fixture"], ["silent-start"], ["silent-replies"]]:
        raise SystemExit(126)
    mode = requested[-1]
    argv = requested[1:]
    if mode == "fixture":
        os.execv(argv[0], argv)

    # Fault injection drops output, not input. EOF still reaches the private
    # tmux client even when no detach acknowledgement can reach Hermit.
    child = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    initial = bytearray()
    attached = False
    selector = selectors.DefaultSelector()
    selector.register(sys.stdin, selectors.EVENT_READ, "input")
    selector.register(child.stdout, selectors.EVENT_READ, "output")
    try:
        while selector.get_map():
            for key, _ in selector.select(timeout=1):
                chunk = os.read(key.fd, 65536)
                if not chunk:
                    selector.unregister(key.fileobj)
                    if key.data == "input":
                        child.stdin.close()
                    continue
                if key.data == "input":
                    try:
                        child.stdin.write(chunk)
                        child.stdin.flush()
                    except BrokenPipeError:
                        selector.unregister(key.fileobj)
                elif mode == "silent-replies" and not attached:
                    initial.extend(chunk)
                    lines = initial.splitlines(keepends=True)
                    if any(line.startswith(b"%end ") and line.endswith(b"\n") for line in lines):
                        for line in lines:
                            os.write(sys.stdout.fileno(), line)
                            if line.startswith(b"%end "):
                                break
                        attached = True
                if child.poll() is not None:
                    return
    finally:
        selector.close()
        if not child.stdin.closed:
            child.stdin.close()
        child.wait(timeout=5)


if __name__ == "__main__":
    main()
