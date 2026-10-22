import fcntl
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import MagicMock, patch

spec = importlib.util.spec_from_file_location("hermit_signing", Path(__file__).parents[1] / "with-hermit-signing.py")
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)


class NoninteractiveSigningTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.home = Path(self.temporary.name)
        self.settings = self.home / ".config/hermit/signing/keychain-passwords.json"
        self.settings.parent.mkdir(parents=True, mode=0o700)
        self.settings.write_text(json.dumps({"keychain": "fixture-password-not-a-secret"}))
        self.settings.chmod(0o600)
        self.security = MagicMock()
        self.security.isolate.return_value = 123
        self.security.unlocked.return_value = True

    def run_main(self, runner):
        with patch.object(signing.Path, "home", return_value=self.home), \
             patch.object(signing, "Security", return_value=self.security), \
             patch.object(signing, "run_command", runner), \
             patch.object(sys, "argv", ["signing", "--", "/usr/bin/true"]):
            return signing.main()

    def test_private_credential(self):
        self.assertEqual(signing.credential(self.settings), b"fixture-password-not-a-secret")

    def test_shared_secret_file_refused(self):
        self.settings.chmod(0o644)
        with self.assertRaises(signing.SigningError): signing.credential(self.settings)

    def test_shared_secret_directory_refused(self):
        self.settings.parent.chmod(0o755)
        with self.assertRaises(signing.SigningError): signing.credential(self.settings)

    def test_symlink_secret_refused(self):
        link = self.settings.with_name("alias.json")
        link.symlink_to(self.settings)
        with self.assertRaises(OSError): signing.credential(link)

    def test_malformed_secret_is_not_echoed(self):
        self.settings.write_text("not-json-sensitive-fixture")
        with self.assertRaises(signing.SigningError) as caught: signing.credential(self.settings)
        self.assertNotIn("not-json-sensitive-fixture", str(caught.exception))

    def test_graphical_session_refused_before_secret_access(self):
        self.security.isolate.side_effect = signing.SigningError("Graphical")
        with patch.object(signing, "credential") as secret:
            with self.assertRaises(signing.SigningError): self.run_main(MagicMock())
            secret.assert_not_called()
        self.security.open.assert_not_called()

    def test_failed_command_relocks(self):
        runner = MagicMock(return_value=17)
        self.assertEqual(self.run_main(runner), 17)
        self.security.lock.assert_called_once()
        self.security.close.assert_called_once()
        self.assertEqual(runner.call_args.args[0], ["/usr/bin/true"])

    def test_timeout_relocks(self):
        with self.assertRaises(subprocess.TimeoutExpired):
            self.run_main(MagicMock(side_effect=subprocess.TimeoutExpired("fixture", 1)))
        self.security.lock.assert_called_once()
        self.security.close.assert_called_once()

    def test_interruption_relocks(self):
        with self.assertRaises(KeyboardInterrupt):
            self.run_main(MagicMock(side_effect=KeyboardInterrupt()))
        self.security.lock.assert_called_once()
        self.security.close.assert_called_once()

    def test_unlock_failure_never_runs_command(self):
        self.security.unlock.side_effect = signing.SigningError("Rejected")
        runner = MagicMock()
        with self.assertRaises(signing.SigningError): self.run_main(runner)
        runner.assert_not_called()
        self.security.lock.assert_called_once()

    def test_concurrent_job_refused(self):
        lock_path = self.settings.with_name("release.lock")
        lock_path.touch(mode=0o600)
        with lock_path.open("wb") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaises(signing.SigningError): self.run_main(MagicMock())
        self.security.unlock.assert_not_called()

    def test_graphics_check_and_optional_ui_disabled(self):
        security = signing.Security.__new__(signing.Security)
        def status(name, *args):
            if name == "SessionGetInfo":
                args[1]._obj.value = 456
                args[2]._obj.value = 0x1000
        security.checked = MagicMock(side_effect=status)
        self.assertEqual(security.isolate(), 456)
        self.assertEqual(security.checked.call_args.args, ("SecKeychainSetUserInteractionAllowed", 0))
        def graphical(name, *args):
            if name == "SessionGetInfo": args[2]._obj.value = 0x10
        security.checked.side_effect = graphical
        with self.assertRaises(signing.SigningError): security.isolate()

    def test_command_gets_closed_stdin_and_reports_exit_code(self):
        result = signing.run_command([sys.executable, "-c", "import sys; assert sys.stdin.read() == ''; sys.exit(7)"], 5)
        self.assertEqual(result, 7)


if __name__ == "__main__": unittest.main()
