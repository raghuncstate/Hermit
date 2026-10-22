#!/usr/bin/env python3
"""Run a release command without keychain UI, using the dedicated Hermit keychain."""
import argparse
import contextlib
import ctypes
import fcntl
import json
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import sys
import tempfile


class SigningError(Exception):
    pass


def private_file(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise SigningError("Signing files must be user-owned, regular files with mode 0600")
        return os.fdopen(fd, "rb")
    except BaseException:
        os.close(fd)
        raise


def credential(path):
    parent = path.parent.lstat()
    if not stat.S_ISDIR(parent.st_mode) or parent.st_uid != os.getuid() or parent.st_mode & 0o077:
        raise SigningError("Signing credential directory must be user-owned with mode 0700")
    with private_file(path) as source:
        raw = source.read(65537)
    try:
        value = json.loads(raw) if len(raw) <= 65536 else None
        password = value.get("keychain") if isinstance(value, dict) else None
        if not isinstance(password, str) or not password or len(password) > 4096:
            raise ValueError()
        return bytearray(password.encode())
    except (ValueError, UnicodeError):
        raise SigningError("Invalid local signing credential; contents withheld") from None


class Security:
    def __init__(self):
        if sys.platform != "darwin":
            raise SigningError("This helper requires macOS")
        self.lib = ctypes.CDLL("/System/Library/Frameworks/Security.framework/Security")
        self.ref = ctypes.c_void_p()
        signatures = {
            "SessionGetInfo": [ctypes.c_uint32, ctypes.POINTER(ctypes.c_uint32), ctypes.POINTER(ctypes.c_uint32)],
            "SecKeychainSetUserInteractionAllowed": [ctypes.c_ubyte],
            "SecKeychainOpen": [ctypes.c_char_p, ctypes.POINTER(ctypes.c_void_p)],
            "SecKeychainGetStatus": [ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint32)],
            "SecKeychainUnlock": [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_ubyte],
            "SecKeychainLock": [ctypes.c_void_p],
        }
        for name, args in signatures.items():
            function = getattr(self.lib, name)
            function.argtypes = args
            function.restype = ctypes.c_int32

    def checked(self, name, *args):
        status = getattr(self.lib, name)(*args)
        if status:
            raise SigningError(f"{name} failed ({status}); no interactive fallback")

    def isolate(self):
        # Run through a batch-only SSH login, even for localhost. Disabling UI
        # in Python alone is insufficient: codesign is a separate process.
        session, attributes = ctypes.c_uint32(), ctypes.c_uint32()
        self.checked("SessionGetInfo", 0xffffffff, ctypes.byref(session), ctypes.byref(attributes))
        if attributes.value & 0x10:
            raise SigningError("Refusing a graphical security session; run through batch-only localhost SSH")
        self.checked("SecKeychainSetUserInteractionAllowed", 0)
        return session.value

    def open(self, path):
        with private_file(path):
            pass
        self.checked("SecKeychainOpen", os.fsencode(path), ctypes.byref(self.ref))

    def unlocked(self):
        flags = ctypes.c_uint32()
        self.checked("SecKeychainGetStatus", self.ref, ctypes.byref(flags))
        return bool(flags.value & 1)

    def unlock(self, password):
        buffer = (ctypes.c_ubyte * len(password)).from_buffer(password)
        self.checked("SecKeychainUnlock", self.ref, len(password), buffer, 1)

    def lock(self):
        self.checked("SecKeychainLock", self.ref)

    def close(self):
        if self.ref:
            core = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
            core.CFRelease.argtypes = [ctypes.c_void_p]
            core.CFRelease(self.ref)
            self.ref = ctypes.c_void_p()


def run_command(command, timeout):
    process = subprocess.Popen(command, stdin=subprocess.DEVNULL, start_new_session=True)
    try:
        return process.wait(timeout=timeout)
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()


def signing_probe(keychain, identity, timeout):
    with tempfile.TemporaryDirectory(prefix="hermit-signing-probe-") as directory:
        target = Path(directory) / "probe"
        shutil.copyfile("/usr/bin/true", target)
        os.chmod(target, 0o700)
        return run_command(["/usr/bin/codesign", "--force", "--sign", identity,
                            "--keychain", str(keychain), "--timestamp=none", str(target)], timeout)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--identity", help="Expected distribution identity SHA-1, required for probes")
    parser.add_argument("--check-context", action="store_true", help="Check non-graphical context only; no keychain access")
    parser.add_argument("--check-locked", action="store_true", help="Verify signing fails without UI while the dedicated keychain is locked")
    parser.add_argument("--probe", action="store_true", help="Unlock, sign a disposable file, and relock")
    parser.add_argument("--timeout", type=float, default=1200)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if sum((args.check_context, args.check_locked, args.probe, bool(command))) != 1 or args.timeout <= 0:
        parser.error("Select one check/probe or a command, and a positive timeout")
    if (args.check_locked or args.probe) and (not args.identity or len(args.identity) != 40 or any(c not in "0123456789abcdefABCDEF" for c in args.identity)):
        parser.error("A SHA-1 identity is required for signing probes")
    os.umask(0o077)
    security = Security()
    session = security.isolate()
    if args.check_context:
        print(json.dumps({"nonGraphical": True, "securitySession": session, "interactiveFallback": False}))
        return 0
    home = Path.home()
    keychain = home / "Library/Keychains/hermit-distribution.keychain-db"
    settings = home / ".config/hermit/signing/keychain-passwords.json"
    password = credential(settings)
    lock_path = settings.with_name("release.lock")
    fd = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "wb") as lock:
        info = os.fstat(lock.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise SigningError("Untrusted release lock")
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise SigningError("Another Hermit signing job is running") from None
        opened = False
        try:
            security.open(keychain)
            opened = True
            if args.check_locked:
                if security.unlocked():
                    raise SigningError("Dedicated keychain is already unlocked; refusing to alter it for a negative test")
                result = signing_probe(keychain, args.identity, min(args.timeout, 15))
                if result == 0:
                    raise SigningError("Locked-keychain probe unexpectedly signed")
                print("Locked-keychain signing failed without UI, as expected.")
                return 0
            security.unlock(password)
            for index in range(len(password)): password[index] = 0
            if not security.unlocked():
                raise SigningError("Dedicated signing keychain did not unlock")
            print("Hermit signing: non-graphical session, dedicated keychain unlocked; no UI fallback.", flush=True)
            return signing_probe(keychain, args.identity, min(args.timeout, 15)) if args.probe else run_command(command, args.timeout)
        finally:
            for index in range(len(password)): password[index] = 0
            try:
                if opened and not args.check_locked:
                    security.lock()
                    print("Hermit signing: dedicated keychain relocked.", flush=True)
            finally:
                security.close()


def interrupted(_signal, _frame):
    raise KeyboardInterrupt()


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGHUP, interrupted)
    try:
        sys.exit(main())
    except (SigningError, OSError, subprocess.TimeoutExpired, KeyboardInterrupt) as error:
        print("Hermit signing stopped: " + (str(error) if isinstance(error, SigningError) else type(error).__name__), file=sys.stderr)
        sys.exit(1)
