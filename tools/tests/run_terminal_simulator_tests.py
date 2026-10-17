"""Run approved iOS UI tests with disposable loopback sshd and isolated tmux."""
import argparse
import getpass
import json
import os
from pathlib import Path
import plistlib
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--simulator", required=True)
    parser.add_argument("--derived-data", type=Path, required=True)
    parser.add_argument("--results", type=Path, required=True)
    parser.add_argument("--packages", type=Path, required=True)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))
    if not any(d["udid"] == args.simulator for group in devices["devices"].values() for d in group):
        raise RuntimeError("Target must be an available simulator, never a physical device")
    if args.results.exists():
        raise RuntimeError("Result path must be new")
    destination = "platform=iOS Simulator,id=" + args.simulator
    subprocess.run(["xcodebuild", "-project", str(repo / "Hermit/Hermit.xcodeproj"), "-scheme", "Hermit",
                    "-configuration", "Debug", "-destination", destination, "-derivedDataPath", str(args.derived_data),
                    "-clonedSourcePackagesDirPath", str(args.packages), "-disableAutomaticPackageResolution",
                    "CODE_SIGNING_ALLOWED=NO", "build-for-testing"], check=True, timeout=600)
    run = max((args.derived_data / "Build/Products").glob("Hermit*.xctestrun"), key=lambda p: p.stat().st_mtime)
    tmux = shutil.which("tmux")
    if not tmux:
        raise RuntimeError("tmux is required")
    socket_name = "hermit-test-foreground-" + uuid.uuid4().hex[:10]
    owned_tmux = [tmux, "-L", socket_name]
    with tempfile.TemporaryDirectory(prefix=".hermit-terminal-test-", dir=Path.home()) as tmp:
        root = Path(tmp)
        root.chmod(0o700)
        for name in ("host", "client"):
            subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(root / name)], check=True)
        with socket.socket() as available:
            available.bind(("127.0.0.1", 0))
            port = available.getsockname()[1]
        # The forced shell consumes the app's launch line but only attaches this
        # fixture. It cannot select the default socket or a user's live session.
        wrapper = root / "shell.sh"
        wrapper.write_text("#!/bin/sh\nIFS= read -r requested || exit 1\nexec " + shlex.join(
            owned_tmux + ["-CC", "new-session", "-A", "-f", "ignore-size", "-s", "foreground"]) + "\n")
        config = root / "sshd_config"
        config.write_text("\n".join([
            "Port " + str(port), "ListenAddress 127.0.0.1", "HostKey " + str(root / "host"),
            "PidFile " + str(root / "sshd.pid"), "AuthorizedKeysFile " + str(root / "client.pub"),
            "PasswordAuthentication no", "KbdInteractiveAuthentication no", "UsePAM no", "PermitRootLogin no",
            "StrictModes yes", "AllowUsers " + getpass.getuser(), "AllowTcpForwarding no", "X11Forwarding no",
            "AllowAgentForwarding no", "PermitTTY yes", "ForceCommand /bin/sh " + shlex.quote(str(wrapper)),
            "LogLevel ERROR", ""]))
        environment = {
            "HERMIT_SIM_SEED_PROFILE": "1", "HERMIT_SIM_HOST_NAME": "Terminal Test", "HERMIT_SIM_HOST": "127.0.0.1",
            "HERMIT_SIM_PORT": str(port), "HERMIT_SIM_USER": getpass.getuser(), "HERMIT_SIM_KEY_PATH": str(root / "client"),
            "HERMIT_SIM_TMUX_SESSION": "foreground", "HERMIT_SIM_TMUX_SOCKET": socket_name, "HERMIT_SIM_TMUX_COMMAND": tmux,
        }
        env_path = root / "environment.json"
        env_path.write_text(json.dumps(environment))
        metadata = plistlib.loads(run.read_bytes())
        for group in metadata["TestConfigurations"]:
            for target in group["TestTargets"]:
                target.setdefault("EnvironmentVariables", {})["HERMIT_TERMINAL_TEST_CONFIG"] = str(env_path)
        run.write_bytes(plistlib.dumps(metadata))
        env = dict(os.environ)
        env.pop("TMUX", None)
        subprocess.run(owned_tmux + ["-f", "/dev/null", "new-session", "-d", "-s", "foreground", "-n", "keys",
                                   shlex.join([sys.executable, str(Path(__file__).with_name("terminal_input_fixture.py"))])],
                       check=True, env=env)
        process = None
        try:
            with (root / "sshd.log").open("w") as log:
                process = subprocess.Popen(["/usr/sbin/sshd", "-D", "-e", "-f", str(config)], stdout=log, stderr=log)
                time.sleep(1)
                if process.poll() is not None:
                    raise RuntimeError("Fixture sshd failed: " + (root / "sshd.log").read_text())
                subprocess.run(["xcodebuild", "test-without-building", "-xctestrun", str(run), "-destination", destination,
                                "-parallel-testing-enabled", "NO", "-resultBundlePath", str(args.results),
                                "-only-testing:HermitTests/TmuxForegroundTests", "-only-testing:HermitUITests/TerminalForegroundUITests"],
                               check=True, timeout=600)
        finally:
            if process is not None and process.poll() is None:
                process.terminate()
                process.wait(timeout=10)
            subprocess.run(owned_tmux + ["kill-server"], check=False, env=env)


if __name__ == "__main__":
    main()
