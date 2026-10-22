"""No UI: test production Swift sources against private tmux and loopback sshd."""
import argparse
import getpass
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import socket
import subprocess
import time
import uuid
from control_fixture_relay import control_argv


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--scratch-path", type=Path, required=True)
    parser.add_argument("--package-directory", type=Path)
    parser.add_argument("--tmux", default=shutil.which("tmux"))
    parser.add_argument("--loss-cycles", type=int, default=5)
    parser.add_argument("--stall-output-seconds", type=float, default=0)
    parser.add_argument("--pipe-loss-cycles", type=int, default=0)
    args = parser.parse_args()
    os.umask(0o077)
    root = args.directory.resolve()
    root.mkdir(mode=0o700)
    repo = Path(__file__).resolve().parents[2]
    package = args.package_directory.resolve() if args.package_directory else root / "package"
    source = package / "Sources/Hermit"
    tests = package / "Tests/HermitTests"
    source.mkdir(parents=True, exist_ok=True)
    tests.mkdir(parents=True, exist_ok=True)
    shutil.copy2(Path(__file__).with_name("control-lifecycle-package") / "Package.swift", package)
    shutil.copy2(repo / "Hermit/Hermit.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved", package)
    sources = ["SSH/SSHConnectionManager.swift", "Storage/KeychainManager.swift", "Models/Host.swift", "Models/RibbonConfig.swift",
               "Tmux/TmuxCommands.swift", "Tmux/TmuxControlClient.swift", "Tmux/TmuxModels.swift", "Tmux/TmuxProtocolParser.swift",
               "Tmux/TmuxWorkspaceModel.swift", "Rendering/AnsiAttributedString.swift"]
    hashes = {}
    for path in sources:
        original = repo / "Hermit/Hermit" / path
        shutil.copy2(original, source / original.name)
        hashes[path] = hashlib.sha256(original.read_bytes()).hexdigest()
    for name in ["TmuxControlClientTests.swift", "TmuxForegroundTests.swift", "TmuxProtocolParserTests.swift"]:
        shutil.copy2(repo / "Hermit/HermitTests" / name, tests / name)
    (root / "tested-source-hashes.json").write_text(json.dumps(hashes, indent=2))

    tmux = str(Path(args.tmux).resolve())
    socket_name = "hermit-control-test-" + uuid.uuid4().hex
    owned = [tmux, "-L", socket_name]
    env = dict(os.environ)
    env.pop("TMUX", None)
    env.pop("TMUX_PANE", None)

    def query(*argv):
        return subprocess.check_output(owned + list(argv), env=env, text=True, timeout=5).strip()

    def fd_count(pid):
        lines = subprocess.check_output(["/usr/sbin/lsof", "-a", "-p", str(pid), "-Ff"], text=True, timeout=5).splitlines()
        return sum(line.startswith("f") and line[1:].isdigit() for line in lines)

    def diagnose_loss(cycle, fixture):
        observations = []
        for delay in (0, 1, 5, 10):
            time.sleep(delay)
            pids = query("list-clients", "-F", "#{client_pid}")
            observations.append({
                "delay": delay,
                "clients": query("list-clients", "-F", "#{client_pid}|#{client_flags}|#{client_name}"),
                "panes": query("list-panes", "-a", "-F", "#{session_id}|#{window_id}|#{pane_id}|#{pane_pid}"),
                "descriptors": fd_count(fixture["serverPID"]),
                "processes": subprocess.run(["ps", "-p", ",".join(pids.splitlines()), "-o", "pid,ppid,stat,etime,args"],
                                            capture_output=True, text=True, timeout=5).stdout,
                "fds": subprocess.run(["/usr/sbin/lsof", "-a", "-p", str(fixture["serverPID"])],
                                      capture_output=True, text=True, timeout=5).stdout,
            })
        (root / "abrupt-loss-failure.json").write_text(json.dumps({"cycle": cycle, "observations": observations}, indent=2))

    sshd = keeper = server = None
    socket_owned = False
    children = []
    try:
        # Keep an owned process handle, including for failed regressions where
        # kill-server itself waits forever for an undrainable control client.
        with (root / "tmux-server.log").open("w") as log:
            server = subprocess.Popen(owned + ["-f", "/dev/null", "-D"], env=env,
                                      stdin=subprocess.DEVNULL, stdout=log, stderr=log)
        for _ in range(100):
            probe = subprocess.run(owned + ["display-message", "-p", "#{pid}"], env=env,
                                   capture_output=True, text=True, timeout=5)
            if probe.returncode == 0:
                if probe.stdout.strip() != str(server.pid):
                    raise RuntimeError("Private fixture socket has an unexpected owner")
                socket_owned = True
                break
            if server.poll() is not None:
                raise RuntimeError("Private fixture server failed to start")
            time.sleep(.02)
        else:
            raise RuntimeError("Private fixture server did not become ready")
        for name in ("fixture", "silent-start", "silent-replies"):
            pane_command = shlex.join([shutil.which("python3"), str(Path(__file__).with_name("control_fixture_output.py"))]) if name == "fixture" else "/bin/sleep 100000"
            subprocess.run(owned + ["-f", "/dev/null", "new-session", "-d", "-s", name, pane_command], env=env, check=True, timeout=5)
        keeper = subprocess.Popen(owned + ["-C", "attach-session", "-t", "fixture"], env=env, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL)
        for _ in range(100):
            if len(query("list-clients", "-F", "#{client_pid}").splitlines()) == 1:
                break
            time.sleep(.02)
        else:
            raise RuntimeError("Unrelated fixture client did not attach")
        for name in ("host", "client"):
            subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(root / name)], check=True, timeout=10)
        with socket.socket() as available:
            available.bind(("127.0.0.1", 0))
            port = available.getsockname()[1]
        fixture_path = root / "fixture.json"
        config = "\n".join([
            "Port " + str(port), "ListenAddress 127.0.0.1", "HostKey " + str(root / "host"),
            "PidFile " + str(root / "sshd.pid"), "AuthorizedKeysFile " + str(root / "client.pub"),
            "PasswordAuthentication no", "KbdInteractiveAuthentication no", "UsePAM no", "PermitRootLogin no",
            "StrictModes yes", "AllowUsers " + getpass.getuser(), "AllowTcpForwarding no", "X11Forwarding no",
            "AllowAgentForwarding no", "PermitTTY no", "LogLevel ERROR",
            "ForceCommand " + shlex.join([shutil.which("python3"), str(Path(__file__).with_name("control_fixture_relay.py")), str(fixture_path)]), ""])
        (root / "sshd_config").write_text(config)
        server_pid = int(query("display-message", "-p", "#{pid}"))
        fixture = {"tmux": tmux, "socket": socket_name, "port": port, "username": getpass.getuser(),
                   "key": str(root / "client"), "serverPID": server_pid,
                   "panes": query("list-panes", "-a", "-F", "#{session_id}|#{window_id}|#{pane_id}|#{pane_pid}"),
                   "sessions": query("list-sessions", "-F", "#{session_id}|#{session_name}"),
                   "clientPIDs": query("list-clients", "-F", "#{client_pid}"),
                   "clients": 1, "descriptors": fd_count(server_pid)}
        fixture_path.write_text(json.dumps(fixture))
        with (root / "sshd.log").open("w") as log:
            sshd = subprocess.Popen(["/usr/sbin/sshd", "-D", "-e", "-f", str(root / "sshd_config")], stdout=log, stderr=log)
            time.sleep(.5)
            if sshd.poll() is not None:
                raise RuntimeError("Fixture sshd failed; see " + str(root / "sshd.log"))
            public = (root / "host.pub").read_text().split()
            (root / "known_hosts").write_text("[127.0.0.1]:" + str(port) + " " + " ".join(public[:2]) + "\n")
            # Abrupt process loss, not just a graceful socket close. This client
            # and all affected remote processes belong exclusively to the fixture.
            for cycle in range(args.loss_cycles):
                command = shlex.join(["exec"] + control_argv(tmux, socket_name, "fixture"))
                child = subprocess.Popen(["ssh", "-F", "/dev/null", "-T", "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes",
                    "-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile=" + str(root / "known_hosts"),
                    "-i", str(root / "client"), "-p", str(port), getpass.getuser() + "@127.0.0.1", command],
                    stdin=subprocess.PIPE, stdout=subprocess.PIPE if args.stall_output_seconds else subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL, env=env)
                children.append(child)
                for _ in range(100):
                    if len(query("list-clients", "-F", "#{client_pid}").splitlines()) == 2:
                        break
                    if child.poll() is not None:
                        raise RuntimeError("Abrupt-loss fixture SSH failed")
                    time.sleep(.02)
                else:
                    raise RuntimeError("Fixture client did not attach")
                if args.stall_output_seconds:
                    time.sleep(args.stall_output_seconds)
                child.kill()
                child.wait(timeout=5)
                child.stdin.close()
                if child.stdout:
                    child.stdout.close()
                for _ in range(100):
                    if len(query("list-clients", "-F", "#{client_pid}").splitlines()) == 1:
                        break
                    time.sleep(.02)
                else:
                    diagnose_loss(cycle, fixture)
                    raise RuntimeError("Abrupt process loss leaked a fixture control client")
                assert query("list-clients", "-F", "#{client_pid}") == fixture["clientPIDs"]
                assert query("display-message", "-p", "#{pid}") == str(server_pid)
                assert query("list-panes", "-a", "-F", "#{session_id}|#{window_id}|#{pane_id}|#{pane_pid}") == fixture["panes"]
                assert query("list-sessions", "-F", "#{session_id}|#{session_name}") == fixture["sessions"]
                assert fd_count(server_pid) <= fixture["descriptors"]
            print(str(args.loss_cycles) + " abrupt SSH process-loss cycles passed; private panes/FDs preserved", flush=True)
            for cycle in range(args.pipe_loss_cycles):
                child = subprocess.Popen(control_argv(tmux, socket_name, "fixture"),
                                         stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                         env=dict(env, SHELLOPTS="errexit:pipefail"))
                children.append(child)
                for _ in range(100):
                    if len(query("list-clients", "-F", "#{client_pid}").splitlines()) == 2:
                        break
                    time.sleep(.02)
                else:
                    raise RuntimeError("Pipe-loss fixture did not attach")
                time.sleep(.25)
                child.stdout.close()
                child.stdin.close()
                for _ in range(100):
                    if query("list-clients", "-F", "#{client_pid}") == fixture["clientPIDs"]:
                        break
                    time.sleep(.02)
                else:
                    diagnose_loss("pipe-" + str(cycle), fixture)
                    raise RuntimeError("Direct pipe loss leaked a fixture control client")
                child.wait(timeout=5)
                assert query("list-panes", "-a", "-F", "#{session_id}|#{window_id}|#{pane_id}|#{pane_pid}") == fixture["panes"]
                assert fd_count(server_pid) <= fixture["descriptors"]
            print(str(args.pipe_loss_cycles) + " abrupt pipe-loss cycles passed; private panes/FDs preserved", flush=True)
            env["HERMIT_CONTROL_FIXTURE"] = str(fixture_path)
            with (root / "swift-tests.log").open("w") as test_log:
                result = subprocess.run(["swift", "test", "--package-path", str(package), "--scratch-path", str(args.scratch_path), "--jobs", "4"],
                                        env=env, stdout=test_log, stderr=subprocess.STDOUT, timeout=900)
            print("Swift test log: " + str(root / "swift-tests.log"), flush=True)
            if result.returncode:
                raise SystemExit(result.returncode)
            assert query("display-message", "-p", "#{pid}") == str(server_pid)
            assert query("list-panes", "-a", "-F", "#{session_id}|#{window_id}|#{pane_id}|#{pane_pid}") == fixture["panes"]
            assert query("list-sessions", "-F", "#{session_id}|#{session_name}") == fixture["sessions"]
            assert query("list-clients", "-F", "#{client_pid}") == fixture["clientPIDs"]
            assert fd_count(server_pid) <= fixture["descriptors"]
            (root / "result.json").write_text(json.dumps({"passed": True, "version": subprocess.check_output([tmux, "-V"], text=True).strip(),
                                                        "abrupt_loss_cycles": args.loss_cycles, "server_pid": server_pid, "panes_preserved": True,
                                                        "pipe_loss_cycles": args.pipe_loss_cycles,
                                                        "foreign_client_preserved": True, "fd_baseline": fixture["descriptors"]}, indent=2))
    finally:
        try:
            for child in children:
                if child.poll() is None:
                    child.kill()
                    child.wait(timeout=5)
            if keeper and keeper.poll() is None:
                keeper.stdin.close()
                try:
                    keeper.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    keeper.kill()
                    keeper.wait(timeout=5)
            if sshd and sshd.poll() is None:
                sshd.terminate()
                try:
                    sshd.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    sshd.kill()
                    sshd.wait(timeout=5)
        finally:
            try:
                # Only the random socket created above, after survival assertions.
                if server and server.poll() is None:
                    if socket_owned:
                        subprocess.run(owned + ["kill-server"], env=env, timeout=5, check=False, stderr=subprocess.DEVNULL)
                        server.wait(timeout=5)
            finally:
                if server and server.poll() is None:
                    server.kill()
                    server.wait(timeout=5)
                for name in ("host", "client"):
                    (root / name).unlink(missing_ok=True)


if __name__ == "__main__":
    main()
