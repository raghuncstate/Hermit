#!/usr/bin/env python3
"""Test Messages with disposable loopback SSH; real test bridges require explicit upstream arguments."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--simulator", required=True, help="An isolated iOS simulator UUID, never a physical device")
    parser.add_argument("--derived-data", required=True, type=Path)
    parser.add_argument("--results", required=True, type=Path, help="New xcresult bundle path")
    parser.add_argument("--packages", type=Path, help="Existing locked Xcode SourcePackages cache")
    parser.add_argument("--upstream-host", help="Explicit opt-in to real inference on an isolated test bridge")
    parser.add_argument("--upstream-root", type=Path)
    parser.add_argument("--provider", choices=("codex", "claude"), default="codex")
    parser.add_argument("--only-testing", action="append", default=[])
    args = parser.parse_args()
    if bool(args.upstream_host) != bool(args.upstream_root):
        parser.error("Both upstream arguments are required")
    repo = Path(__file__).resolve().parents[2]
    destination = "platform=iOS Simulator,id=" + args.simulator
    build = ["xcodebuild", "-project", str(repo / "Hermit/Hermit.xcodeproj"), "-scheme", "Hermit", "-configuration", "Debug",
             "-destination", destination, "-derivedDataPath", str(args.derived_data), "CODE_SIGNING_ALLOWED=NO", "build-for-testing"]
    if args.packages:
        build.extend(["-clonedSourcePackagesDirPath", str(args.packages), "-disableAutomaticPackageResolution"])
    subprocess.run(build, check=True, timeout=600)
    runs = list((args.derived_data / "Build/Products").glob("Hermit*.xctestrun"))
    if not runs: raise RuntimeError("Xcode did not produce a test-run configuration")
    run = max(runs, key=lambda path: path.stat().st_mtime)
    # Keep socket paths short and keys below the user's home for sshd StrictModes.
    with tempfile.TemporaryDirectory(prefix=".hermit-ssh-test-", dir=Path.home()) as tmp:
        root = Path(tmp)
        fixture = root / "fixture"
        with (root / "fixture.log").open("w") as log:
            fixture_command = [sys.executable, str(Path(__file__).with_name("run_agent_ssh_fixture.py")), "--directory", str(fixture)]
            if args.upstream_host:
                fixture_command.extend(["--upstream-host", args.upstream_host, "--upstream-root", str(args.upstream_root), "--provider", args.provider])
            process = subprocess.Popen(fixture_command, stdout=log, stderr=log, start_new_session=True)
            try:
                for _ in range(100):
                    if (fixture / "config.json").exists(): break
                    if process.poll() is not None:
                        raise RuntimeError("SSH fixture failed: " + (root / "fixture.log").read_text()[-4000:])
                    time.sleep(0.1)
                else: raise RuntimeError("SSH fixture did not become ready")
                settings = json.loads((fixture / "config.json").read_text())
                known_hosts = root / "known_hosts"
                known_hosts.write_text("[127.0.0.1]:" + str(settings["port"]) + " " + " ".join(settings["publicHostKey"]) + "\n")
                probe = subprocess.run(["ssh", "-F", "/dev/null", "-T", "-p", str(settings["port"]), "-i", settings["privateKeyPath"],
                                        "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=yes",
                                        "-o", "UserKnownHostsFile=" + str(known_hosts), "-o", "ConnectTimeout=5",
                                        settings["username"] + "@127.0.0.1", "fixture-probe"],
                                       input='{"id":"probe","method":"hello","params":{}}\n', text=True,
                                       capture_output=True, timeout=15, check=True)
                if json.loads(probe.stdout).get("result", {}).get("version") != 1:
                    raise RuntimeError("SSH fixture did not pass the private handshake probe")
                config = plistlib.loads(run.read_bytes())
                for group in config["TestConfigurations"]:
                    for target in group["TestTargets"]:
                        target.setdefault("EnvironmentVariables", {})["HERMIT_AGENT_TEST_CONFIG"] = str(fixture / "config.json")
                # Generated test metadata only; never writes a credential into the app bundle.
                run.write_bytes(plistlib.dumps(config))
                subprocess.run(["xcodebuild", "test-without-building", "-xctestrun", str(run), "-destination", destination,
                                "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never",
                                "-resultBundlePath", str(args.results)]
                               + ["-only-testing:" + item for item in args.only_testing], check=True, timeout=600)
            finally:
                if process.poll() is None:
                    process.send_signal(signal.SIGINT)
                    try: process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGTERM); process.wait(timeout=10)


if __name__ == "__main__":
    main()
