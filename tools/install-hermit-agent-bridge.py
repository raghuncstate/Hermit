#!/usr/bin/env python3
"""Install the optional private Messages service. Does not alter Hermit tunnel or tmux jobs."""
import argparse
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
import uuid

LABEL = "com.hermit.agent-messages"


def install_environment(python, destination, requirements):
    has_ensurepip = subprocess.run([python, "-c", "import ensurepip"],
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
    if not has_ensurepip:
        # Debian can omit ensurepip; an existing recent pip can target a bare venv.
        subprocess.run([python, "-m", "pip", "--python", python, "--version"], check=True)
    subprocess.run([python, "-m", "venv"] + ([] if has_ensurepip else ["--without-pip"])
                   + [str(destination)], check=True)
    target = str(destination / "bin/python")
    pip = [target, "-m", "pip"] if has_ensurepip else [python, "-m", "pip", "--python", target]
    subprocess.run(pip + ["install", "--disable-pip-version-check", "--no-cache-dir", "-r", str(requirements)], check=True)


def atomic_write(path, data, mode=0o600):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_symlink():
        raise RuntimeError("Refusing to replace symlink: " + str(path))
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix=".hermit-install-")
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "wb") as out:
            out.write(data); out.flush(); os.fsync(out.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary): os.unlink(temporary)


def configuration(home, python, source, platform):
    path = ":".join([str(home / ".local/bin"), "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"])
    state = home / ".local/state/hermit-agent-bridge"
    argv = [str(python), str(source), "serve"]
    if platform == "darwin":
        destination = home / "Library/LaunchAgents" / (LABEL + ".plist")
        data = plistlib.dumps({"Label": LABEL, "ProgramArguments": argv,
                              "RunAtLoad": True, "KeepAlive": True, "ThrottleInterval": 60,
                              "EnvironmentVariables": {"HOME": str(home), "PATH": path},
                              "StandardOutPath": str(state / "service.log"), "StandardErrorPath": str(state / "service-error.log")})
    elif platform.startswith("linux"):
        destination = home / ".config/systemd/user" / (LABEL + ".service")
        def quote(value):
            return '"' + str(value).replace("\\", "\\\\").replace('"', '\\"').replace("%", "%%") + '"'
        data = ("[Unit]\nDescription=Hermit private agent messages\nAfter=network.target\n\n[Service]\nType=simple\n"
                + "ExecStart=" + " ".join(quote(x) for x in argv) + "\n"
                + "Environment=" + quote("HOME=" + str(home)) + " " + quote("PATH=" + path) + "\n"
                + "UMask=0077\nRestart=on-failure\nRestartSec=60\n\n[Install]\nWantedBy=default.target\n").encode()
    else:
        raise RuntimeError("Only macOS launchd and Linux user systemd services are supported")
    return destination, data, path


def install(args):
    os.umask(0o077)
    home = Path.home()
    root = home / ".local/lib/hermit-agent-bridge"
    state = home / ".local/state/hermit-agent-bridge"
    release = root / "releases" / uuid.uuid4().hex
    python = release / "venv/bin/python"
    script = release / "hermit_agent_bridge.py"
    service, data, path = configuration(home, python, script, sys.platform)
    launcher = home / ".local/bin/hermit-agent-bridge"
    if args.dry_run:
        print(json.dumps({"service": str(service), "launcher": str(launcher), "state": str(state), "start": args.start, "publicListener": False}, indent=2))
        return
    # Refuse an in-place upgrade of a live service. Disconnecting its clients is not enough.
    if (state / "bridge.sock").exists():
        probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            probe.settimeout(2); probe.connect(str(state / "bridge.sock"))
        except ConnectionRefusedError:
            pass
        else:
            raise RuntimeError("The Messages service is active. Installation refused to preserve its conversations.")
        finally:
            probe.close()
    if service.exists() or launcher.exists():
        raise RuntimeError("A Messages installation already exists; review and back it up before an explicit upgrade")
    version = subprocess.check_output([args.python, "-c", "import sys; print('%d.%d' % sys.version_info[:2])"], text=True).strip()
    if tuple(map(int, version.split('.'))) < (3, 10):
        raise RuntimeError("Python 3.10 or newer is required for the Claude Agent SDK")
    for directory in (root, state):
        directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        info = directory.lstat()
        if directory.is_symlink() or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise RuntimeError("Installation directories must be user-owned, non-symlink, mode 0700")
    release.mkdir(parents=True, mode=0o700)
    requirements = Path(__file__).with_name("agent-bridge-requirements.txt")
    install_environment(args.python, release / "venv", requirements)
    shutil.copyfile(Path(__file__).with_name("hermit_agent_bridge.py"), script)
    os.chmod(script, 0o600)
    wrapper = "#!/bin/sh\nexport PATH=" + shlex.quote(path) + "\nexec " + shlex.quote(str(python)) + " " + shlex.quote(str(script)) + ' "$@"\n'
    atomic_write(launcher, wrapper.encode(), 0o700)
    atomic_write(service, data)
    if args.start:
        if sys.platform == "darwin":
            subprocess.run(["launchctl", "bootstrap", "gui/" + str(os.getuid()), str(service)], check=True)
        else:
            subprocess.run(["systemctl", "--user", "daemon-reload"], check=True)
            subprocess.run(["systemctl", "--user", "enable", "--now", LABEL + ".service"], check=True)
    print("Installed " + str(service) + (" and started the Messages service." if args.start else "; not started."))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--python", default=sys.executable, help="Python 3.10+ executable for the isolated SDK environment")
    parser.add_argument("--start", action="store_true", help="Start this new service now and at subsequent user logins")
    parser.add_argument("--dry-run", action="store_true", help="Print destinations without creating or changing anything")
    try:
        install(parser.parse_args())
    except (RuntimeError, OSError, subprocess.CalledProcessError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
