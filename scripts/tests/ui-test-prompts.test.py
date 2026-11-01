"""Prompt-guard regression tests using real, test-owned harmless child processes.

Run: python3 scripts/tests/ui-test-prompts.test.py
Only the external window-list boundary is mocked in the launch-gap case. The
native CoreGraphics window check is paired with ui-tests.sh's pre-run check.
"""

import importlib.util
import json
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "ui-test-prompts.py"
SPEC = importlib.util.spec_from_file_location("ui_test_prompts", SCRIPT)
guard = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(guard)


class PromptGuardTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="picsee-prompt-test-")
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name).resolve()
        self.result = str(self.base / "run.xcresult")
        self.derived = str(self.base / "dd")
        # Apple tail preserves argv[0]; Apple's Python launcher rewrites it.
        self.transport = self.base / "xcodebuild"
        self.children = []
        self.addCleanup(self.stop_children)

    def stop_children(self):
        for child in self.children:
            if child.poll() is None:
                child.terminate()
            try:
                child.wait(timeout=3)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait(timeout=3)

    def spawn_job(self, marker):
        # Execute Apple tail directly with test-only argv[0]. No signed binary
        # is copied/modified, and no Xcode build or GUI operation is started.
        fake_executable = str(self.transport)
        Path(marker).touch()
        child = subprocess.Popen(
            [fake_executable, "-f", marker],
            executable="/usr/bin/tail",
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.children.append(child)
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            command = guard.processes().get(child.pid, "")
            try:
                args = shlex.split(command)
            except ValueError:
                args = []
            if args and args[0] == fake_executable and marker in args:
                return child
            if child.poll() is not None:
                break
            time.sleep(0.02)
        self.fail("Cannot simulate safe xcodebuild argv ownership with real ps on this host; "
                  f"child={child.pid}, command={guard.processes().get(child.pid)!r}")

    def terminated_status(self, child):
        try:
            return child.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.fail(f"owned real job PID={child.pid} remained alive instead of receiving SIGTERM")

    def test_shutdown_ignores_unmatched_quote_and_preserves_other_runs_and_baseline(self):
        prior = self.spawn_job(self.result)
        baseline = guard.processes()
        owned = self.spawn_job(self.result)
        # Contains the same substring but is not the exact result-path argument.
        other = self.spawn_job(self.result + ".other-run")
        real_processes = guard.processes

        def rows_with_unrelated_bad_quote():
            return {999999999: "unrelated '" + self.result, **real_processes()}

        error = None
        with mock.patch.object(guard, "processes", side_effect=rows_with_unrelated_bad_quote):
            try:
                guard.stop_run(self.result, self.derived, baseline)
            except Exception as caught:
                error = caught
        self.assertIsNone(error, "an unrelated malformed command must not abort owned shutdown")
        self.assertEqual(self.terminated_status(owned), -signal.SIGTERM,
                         "the real child belonging to this run must receive SIGTERM")
        self.assertIsNone(other.poll(), "a different run's real child must remain alive")
        self.assertIsNone(prior.poll(), "a preexisting real child must remain alive")

    def test_prompt_before_job_launch_keeps_guarding_until_parent_stop(self):
        stop = self.base / "monitor.stop"
        evidence = self.base / "prompt.json"
        ready = self.base / "monitor.ready"
        prompt = [{"owner": "UserNotificationCenter", "pid": 123,
                   "window": 456, "title": "Test prompt; no real privacy prompt was opened"}]
        outcomes, errors = [], []

        def monitor():
            try:
                outcomes.append(guard.main())
            except Exception as error:
                errors.append(error)

        argv = [str(SCRIPT), "watch", self.result, self.derived,
                str(stop), str(evidence), str(ready)]
        with mock.patch.object(guard, "windows", return_value=prompt), mock.patch.object(sys, "argv", argv):
            thread = threading.Thread(target=monitor, name="test-owned-prompt-monitor", daemon=True)
            thread.start()
            try:
                deadline = time.monotonic() + 3
                while not evidence.exists() and time.monotonic() < deadline and thread.is_alive():
                    time.sleep(0.02)
                self.assertTrue(evidence.exists(), "detection must leave prompt evidence before job launch")
                self.assertEqual(json.loads(evidence.read_text())["UserNotificationCenterWindows"], prompt)
                self.assertTrue(thread.is_alive(), "monitor must cover the gap after detection and before launch")
                # Both jobs start after detection/baseline capture, so another-run
                # survival cannot be explained merely by its presence in baseline.
                other = self.spawn_job(self.result + ".other-run")
                owned = self.spawn_job(self.result)
                self.assertEqual(self.terminated_status(owned), -signal.SIGTERM,
                                 "the later real job must be stopped after earlier prompt detection")
                self.assertIsNone(other.poll(), "later unrelated run must survive")
                self.assertTrue(thread.is_alive(), "monitor exits only after parent acknowledgement")
            finally:
                stop.touch()
                thread.join(timeout=3)
        self.assertFalse(thread.is_alive(), "parent stop must end the monitor")
        self.assertEqual(errors, [])
        self.assertEqual(outcomes, [78], "a detected prompt remains a stopped-run result")


if __name__ == "__main__":
    unittest.main(verbosity=2)
