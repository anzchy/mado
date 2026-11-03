import fcntl
import os
import re
import stat
import subprocess
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch


SCRIPT = Path(__file__).with_name("gui-lock.sh")
# Optional real mdpro GUI script: PICSEE_MDPRO_SCRIPT must name it in its repository,
# so its repository-relative heavy-lock dependency remains available. Never copy it.
UUID4 = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\Z")
ACQUIRED = re.compile(r"ACQUIRED (\S+) acquisition_id=(\S+)\n\Z")
FIELDS = ["project", "session", "batch", "start", "pid", "expected_minutes", "purpose", "acquisition_id"]
OTHER_ID = "123e4567-e89b-42d3-a456-426614174000"


def owner_text(project="picsee", batch="run-1", acquisition_id=OTHER_ID):
    return (f"project={project}\nsession=s\nbatch={batch}\nstart=2026-10-28T00:00:00+0000\npid=123\n"
            f"expected_minutes=30\npurpose=device run\nacquisition_id={acquisition_id}\n")


class GuiLockBase(unittest.TestCase):
    def setUp(self):
        # A temporary HOME: the real ~/.cache/desktop-gui.lock and .mutex are never touched.
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.cache = self.home / ".cache"
        self.lock = self.cache / "desktop-gui.lock"
        self.owner = self.lock / "owner"
        self.mutex = self.cache / "desktop-gui.mutex"
        self.env = {**os.environ, "HOME": str(self.home), "PICSEE_GUI_LOCK_TEST": "1",
                    "PICSEE_GUI_LOCK_WAIT_SECONDS": "0.05"}

    def run_lock(self, *args, script=SCRIPT, env=None):
        return subprocess.run(["zsh", str(script), *args], capture_output=True, text=True,
                              env=env or self.env, timeout=30)

    def acquire(self, run="run-1", *rest):
        result = self.run_lock("acquire", run, *rest)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        match = ACQUIRED.fullmatch(result.stdout)
        self.assertIsNotNone(match, result.stdout)
        self.assertEqual(match.group(1), run)
        return match.group(2)

    def checkpoint_env(self, name):
        return {**self.env, "PICSEE_GUI_LOCK_PRE_MUTEX_FILE": str(self.home / f"pre-mutex-{name}")}

    def wait_for_checkpoint(self, name):
        # The child has reached the flock call; give it time to return if the mutex were not held.
        deadline = time.monotonic() + 20
        while not (self.home / f"pre-mutex-{name}").exists():
            self.assertLess(time.monotonic(), deadline, "child never reached the mutex")
            time.sleep(0.02)
        time.sleep(0.3)

    def plant(self, text):
        self.lock.mkdir(parents=True)
        self.owner.write_text(text)
        return text

    def assert_refused_intact(self, result, text):
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("REFUSED", result.stderr)
        self.assertTrue(self.lock.is_dir())
        self.assertEqual(self.owner.read_text(), text)


class GuiLockTests(GuiLockBase):
    def test_round_trip_writes_owner_and_releases_it(self):
        acquisition_id = self.acquire("run-1", "12", "parity batch", "sess-a")
        self.assertRegex(acquisition_id, UUID4)
        lines = self.owner.read_text().splitlines()
        self.assertEqual([line.split("=", 1)[0] for line in lines], FIELDS)
        values = dict(line.split("=", 1) for line in lines)
        self.assertEqual(values["project"], "picsee")
        self.assertEqual(values["session"], "sess-a")
        self.assertEqual(values["batch"], "run-1")
        self.assertEqual(values["expected_minutes"], "12")
        self.assertEqual(values["purpose"], "parity batch")
        self.assertEqual(values["acquisition_id"], acquisition_id)
        self.assertRegex(values["start"], r"\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d[+-]\d{4}\Z")
        self.assertRegex(values["pid"], r"\A[1-9]\d*\Z")
        self.assertEqual(stat.S_IMODE(self.owner.stat().st_mode), 0o600)
        inode = self.mutex.stat().st_ino
        result = self.run_lock("release", "run-1", "--acquisition-id", acquisition_id)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("RELEASED run-1", result.stdout)
        self.assertFalse(self.lock.exists())
        self.assertEqual(self.mutex.stat().st_ino, inode)
        self.assertEqual(self.run_lock("status").stdout, "FREE\n")

    def test_defaults_fill_the_owner(self):
        self.acquire("run-1")
        values = dict(line.split("=", 1) for line in self.owner.read_text().splitlines())
        self.assertEqual((values["expected_minutes"], values["purpose"], values["session"]),
                         ("30", "device run", "picsee-delegator"))

    def test_each_acquisition_gets_a_fresh_id_and_a_stale_id_is_refused(self):
        first = self.acquire("run-1")
        self.assertEqual(self.run_lock("release", "run-1", "--acquisition-id", first).returncode, 0)
        second = self.acquire("run-1")
        self.assertNotEqual(first, second)
        text = self.owner.read_text()
        self.assert_refused_intact(self.run_lock("release", "run-1", "--acquisition-id", first), text)

    def test_busy_exits_75_and_keeps_the_holder(self):
        text = self.plant(owner_text(project="mdpro"))
        result = self.run_lock("acquire", "run-2")
        self.assertEqual(result.returncode, 75)
        self.assertIn("BUSY", result.stderr)
        self.assertEqual(self.owner.read_text(), text)

    def test_wait_times_out_with_75(self):
        text = self.plant(owner_text(project="mdpro"))
        result = self.run_lock("wait", "run-2", "30", "device run", "s", "2")
        self.assertEqual(result.returncode, 75)
        self.assertIn("TIMEOUT", result.stderr)
        self.assertEqual(self.owner.read_text(), text)

    def test_wait_acquires_once_the_holder_releases(self):
        held = self.acquire("run-1")
        waiter = subprocess.Popen(["zsh", str(SCRIPT), "wait", "run-2", "30", "p", "s", "100"],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                  env={**self.env, "PICSEE_GUI_LOCK_WAIT_SECONDS": "0.02"})
        time.sleep(0.2)
        self.assertEqual(self.run_lock("release", "run-1", "--acquisition-id", held).returncode, 0)
        out, err = waiter.communicate(timeout=30)
        self.assertEqual(waiter.returncode, 0, err)
        self.assertRegex(out, ACQUIRED)
        self.assertIn("batch=run-2\n", self.owner.read_text())

    def test_release_refuses_wrong_id_foreign_project_and_wrong_batch(self):
        own = self.acquire("run-1")
        text = self.owner.read_text()
        self.assert_refused_intact(self.run_lock("release", "run-1", "--acquisition-id", OTHER_ID), text)
        self.assert_refused_intact(self.run_lock("release", "run-9", "--acquisition-id", own), text)
        self.owner.unlink()
        self.lock.rmdir()
        foreign = self.plant(owner_text(project="mdpro"))
        self.assert_refused_intact(self.run_lock("release", "run-1", "--acquisition-id", OTHER_ID), foreign)

    def test_release_refuses_malformed_owners(self):
        good = owner_text()
        variants = {
            "missing id": good.replace(f"acquisition_id={OTHER_ID}\n", ""),
            "duplicate id": good + f"acquisition_id={OTHER_ID}\n",
            "duplicate project": good + "project=picsee\n",
            "unknown field": good + "host=mini\n",
            "renamed field": good.replace("batch=", "run="),
            "line without =": good + "garbage\n",
            "empty value": good.replace("session=s", "session="),
            "uppercase id": good.replace(OTHER_ID, OTHER_ID.upper()),
            "non-v4 id": good.replace(OTHER_ID, "123e4567-e89b-12d3-a456-426614174000"),
            "malformed id": good.replace(OTHER_ID, "not-a-uuid"),
        }
        for name, text in variants.items():
            with self.subTest(name):
                self.plant(text)
                self.assert_refused_intact(self.run_lock("release", "run-1", "--acquisition-id", OTHER_ID), text)
                self.owner.unlink()
                self.lock.rmdir()

    def test_release_refuses_non_utf8_and_oversized_owners(self):
        for name, raw in {"non-utf8": owner_text().encode() + b"purpose=\xff\n",
                          "oversized": owner_text().encode() + b"x" * 9000}.items():
            with self.subTest(name):
                self.lock.mkdir(parents=True)
                self.owner.write_bytes(raw)
                result = self.run_lock("release", "run-1", "--acquisition-id", OTHER_ID)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertEqual(self.owner.read_bytes(), raw)
                self.owner.unlink()
                self.lock.rmdir()

    def test_release_refuses_a_missing_owner_or_a_free_lock(self):
        self.lock.mkdir(parents=True)
        result = self.run_lock("release", "run-1", "--acquisition-id", OTHER_ID)
        self.assertEqual(result.returncode, 1)
        self.assertTrue(self.lock.is_dir())
        self.lock.rmdir()
        self.assertEqual(self.run_lock("release", "run-1", "--acquisition-id", OTHER_ID).returncode, 1)

    def test_release_refuses_a_symlinked_owner(self):
        target = self.home / "elsewhere"
        target.write_text(owner_text())
        self.lock.mkdir(parents=True)
        self.owner.symlink_to(target)
        result = self.run_lock("release", "run-1", "--acquisition-id", OTHER_ID)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertTrue(self.owner.is_symlink())
        self.assertEqual(target.read_text(), owner_text())

    def test_symlinked_lock_directory_is_busy_and_cannot_be_released(self):
        real = self.home / "real-lock"
        real.mkdir()
        (real / "owner").write_text(owner_text())
        self.cache.mkdir()
        self.lock.symlink_to(real)
        self.assertEqual(self.run_lock("acquire", "run-2").returncode, 75)
        result = self.run_lock("release", "run-1", "--acquisition-id", OTHER_ID)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertTrue(self.lock.is_symlink())
        self.assertEqual((real / "owner").read_text(), owner_text())
        self.assertIn("invalid lock path", self.run_lock("status").stdout)

    def test_usage_errors_are_refused(self):
        for args in (["release", "run-1"], ["release", "run-1", "--acquisition-id", "nope"],
                     ["acquire"], ["acquire", "run-1", "0"], ["acquire", "run-1", "ten"],
                     ["acquire", "bad\nrun"], ["frobnicate"]):
            with self.subTest(args=args):
                result = self.run_lock(*args)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertFalse(self.lock.exists())

    def test_parallel_acquirers_have_exactly_one_winner(self):
        procs = [subprocess.Popen(["zsh", str(SCRIPT), "acquire", f"run-{i}"], stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, text=True, env=self.env) for i in range(12)]
        results = [(p, *p.communicate(timeout=30)) for p in procs]
        winners = [(p, out) for p, out, _ in results if p.returncode == 0]
        self.assertEqual(len(winners), 1)
        self.assertEqual(sorted(p.returncode for p, _, _ in results), [0] + [75] * 11)
        run, acquisition_id = ACQUIRED.fullmatch(winners[0][1]).groups()
        self.assertIn(f"batch={run}\n", self.owner.read_text())
        self.assertIn(f"acquisition_id={acquisition_id}\n", self.owner.read_text())

    def test_release_restores_owner_bytes_when_rmdir_fails(self):
        acquisition_id = self.acquire("run-1")
        before = self.owner.read_bytes()
        extra = self.lock / "extra"
        extra.write_text("x")
        result = self.run_lock("release", "run-1", "--acquisition-id", acquisition_id)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("owner restored", result.stderr)
        self.assertEqual(self.owner.read_bytes(), before)
        self.assertEqual(self.owner.stat().st_mode & 0o777, 0o600)
        extra.unlink()
        result = self.run_lock("release", "run-1", "--acquisition-id", acquisition_id)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(self.lock.exists())

    def test_acquire_refuses_values_the_parser_would_split(self):
        for bad in ["run\x0bx", "run\x0cx", "run\x1cx", "run\x85x", "run\u2028x", "run\u2029x"]:
            with self.subTest(bad=repr(bad)):
                result = self.run_lock("acquire", bad)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertFalse(self.lock.exists())

    def test_acquire_and_release_wait_for_the_mutex(self):
        self.cache.mkdir()
        fd = os.open(self.mutex, os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            proc = subprocess.Popen(["zsh", str(SCRIPT), "acquire", "run-1"], stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE, text=True, env=self.checkpoint_env("a"))
            self.wait_for_checkpoint("a")
            self.assertIsNone(proc.poll())
            self.assertFalse(self.lock.exists())
            fcntl.flock(fd, fcntl.LOCK_UN)
            out, err = proc.communicate(timeout=30)
            self.assertEqual(proc.returncode, 0, err)
            acquisition_id = ACQUIRED.fullmatch(out).group(2)
            fcntl.flock(fd, fcntl.LOCK_EX)
            proc = subprocess.Popen(["zsh", str(SCRIPT), "release", "run-1", "--acquisition-id", acquisition_id],
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                    env=self.checkpoint_env("r"))
            self.wait_for_checkpoint("r")
            self.assertIsNone(proc.poll())
            self.assertTrue(self.owner.exists())
            fcntl.flock(fd, fcntl.LOCK_UN)
            proc.communicate(timeout=30)
            self.assertEqual(proc.returncode, 0)
            self.assertFalse(self.lock.exists())
        finally:
            os.close(fd)


class MdproInteropTests(GuiLockBase):
    def setUp(self):
        super().setUp()
        script = os.environ.get("PICSEE_MDPRO_SCRIPT")
        if not script:
            self.skipTest("PICSEE_MDPRO_SCRIPT not set (requires mdpro GUI script)")
        self.mdpro = Path(script).expanduser().resolve()
        if not self.mdpro.is_file():
            self.skipTest(f"mdpro GUI script unavailable: {self.mdpro}")
        # Same layout used by mdpro's gui-lock.sh when locating this dependency.
        self.mdpro_heavy = self.mdpro.parent.joinpath("../../../..", "scripts/heavy-lock.sh").resolve()
        if not self.mdpro_heavy.is_file():
            self.skipTest(f"mdpro heavy-lock script unavailable: {self.mdpro_heavy}")
        self.mdpro_env = {key: value for key, value in self.env.items() if not key.startswith("MDPRO_")}
        # Exercise real lock ownership, with mdpro's supported deterministic
        # admission sample; host memory pressure is outside this fixture's scope.
        self.mdpro_env.update({"MDPRO_HEAVY_LOCK": str(self.home / "mdpro-heavy.lock"),
                               "MDPRO_GUARD_TEST": "1",
                               "MDPRO_LOAD_GUARD_LOG": str(self.home / "load-guard.log"),
                               "MDPRO_LOAD_GUARD_ACTIVE": str(self.home / "load-guard-active"),
                               "TMPDIR": str(self.home),
                               "PICSEE_MDPRO_LOCK": str(self.home / "mdpro-heavy.lock"),
                               "PICSEE_HEAVY_LOCK": str(self.home / "picsee-heavy.lock")})

    def run_mdpro(self, *args):
        result = self.run_lock(*args, script=self.mdpro, env=self.mdpro_env)
        if args[0] == "acquire" and result.returncode == 0:
            acquisition_id = result.stdout.strip().removeprefix("acquisition_id=")
            if UUID4.fullmatch(acquisition_id):
                self.addCleanup(self.release_mdpro_keeper, acquisition_id)
        return result

    def release_mdpro_keeper(self, acquisition_id):
        # Normal GUI release already stops the keeper. On assertion failure, stop
        # only this test's keeper before TemporaryDirectory removes its owner.
        if Path(self.mdpro_env["MDPRO_HEAVY_LOCK"]).exists():
            result = subprocess.run([str(self.mdpro_heavy), "--release", acquisition_id],
                                    env=self.mdpro_env, capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_mdpro_lock_is_busy_for_picsee_and_not_releasable(self):
        result = self.run_mdpro("acquire", "batch-m")
        self.assertEqual(result.returncode, 0, result.stderr)
        mdpro_id = result.stdout.strip().removeprefix("acquisition_id=")
        self.assertRegex(mdpro_id, UUID4)
        text = self.owner.read_text()
        self.assertEqual(self.run_lock("acquire", "batch-m").returncode, 75)
        self.assert_refused_intact(self.run_lock("release", "batch-m", "--acquisition-id", mdpro_id), text)
        self.assertEqual(self.run_mdpro("release", "batch-m", "--acquisition-id", mdpro_id).returncode, 0)
        self.assertFalse(self.lock.exists())

    def test_picsee_lock_is_busy_for_mdpro_and_not_releasable(self):
        picsee_id = self.acquire("batch-p")
        text = self.owner.read_text()
        self.assertEqual(self.run_mdpro("acquire", "batch-p").returncode, 75)
        result = self.run_mdpro("release", "batch-p", "--acquisition-id", picsee_id)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not this acquisition", result.stderr)  # mdpro parsed picsee's owner as well formed
        self.assertEqual(self.owner.read_text(), text)
        self.assertEqual(self.run_lock("release", "batch-p", "--acquisition-id", picsee_id).returncode, 0)
        self.assertFalse(self.lock.exists())


class MdproInteropFixtureTests(unittest.TestCase):
    def interop_result(self, script):
        env = dict(os.environ)
        env.pop("PICSEE_MDPRO_SCRIPT", None)
        if script is not None:
            env["PICSEE_MDPRO_SCRIPT"] = str(script)
        result = unittest.TestResult()
        with patch.dict(os.environ, env, clear=True):
            unittest.defaultTestLoader.loadTestsFromTestCase(MdproInteropTests).run(result)
        return result

    def assert_pair_skipped(self, script, reason):
        result = self.interop_result(script)
        self.assertEqual(result.testsRun, 2)
        self.assertEqual(result.failures + result.errors, [])
        self.assertEqual(len(result.skipped), 2)
        for _, message in result.skipped:
            self.assertIn(reason, message)

    def test_unset_script_skips_explicitly(self):
        self.assert_pair_skipped(None, "PICSEE_MDPRO_SCRIPT not set")

    def test_unavailable_script_or_dependency_skips_explicitly(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.assert_pair_skipped(root / "missing.sh", "missing.sh")
            self.assert_pair_skipped(root, str(root))
            script = root / ".agents/skills/mdpro-delegator/scripts/gui-lock.sh"
            script.parent.mkdir(parents=True)
            script.write_text("exit 42\n")
            self.assert_pair_skipped(script, "heavy-lock.sh")

    def test_present_broken_script_is_not_skipped(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            script = root / ".agents/skills/mdpro-delegator/scripts/gui-lock.sh"
            script.parent.mkdir(parents=True)
            script.write_text("exit 42\n")
            heavy = root / "scripts/heavy-lock.sh"
            heavy.parent.mkdir()
            heavy.write_text("exit 42\n")
            result = self.interop_result(script)
        self.assertEqual(result.testsRun, 2)
        self.assertEqual(result.skipped + result.errors, [])
        self.assertEqual(len(result.failures), 2)
        self.assertTrue(all("42" in failure for _, failure in result.failures))

    def test_failed_assertion_releases_keeper_and_preserves_inherited_paths(self):
        checked = []

        class AbortedInterop(MdproInteropTests):
            def test_abort(inner):
                def check_keeper_released():
                    self.assertTrue(inner.home.is_dir(), "check before temporary HOME cleanup")
                    self.assertFalse(Path(inner.mdpro_env["MDPRO_HEAVY_LOCK"]).exists())
                    checked.append(True)
                inner.addCleanup(check_keeper_released)
                result = inner.run_mdpro("acquire", "aborted-test")
                inner.assertEqual(result.returncode, 0, result.stderr)
                inner.fail("deliberate assertion after acquisition")

        with tempfile.TemporaryDirectory() as directory:
            sentinel = Path(directory) / "untouched-lock"
            sentinel.mkdir()
            owner = sentinel / "owner"
            owner.write_text("sentinel owner bytes\n")
            result = unittest.TestResult()
            with patch.dict(os.environ, {"MDPRO_HEAVY_LOCK": str(sentinel),
                                         "PICSEE_MDPRO_LOCK": str(sentinel),
                                         "MDPRO_LOAD_GUARD_LOG": str(owner),
                                         "MDPRO_LOAD_GUARD_ACTIVE": str(sentinel)}):
                AbortedInterop("test_abort").run(result)
            self.assertEqual(owner.read_text(), "sentinel owner bytes\n")
            self.assertEqual(list(sentinel.iterdir()), [owner])
        if result.skipped:
            self.skipTest(result.skipped[0][1])
        self.assertEqual(result.errors, [])
        self.assertEqual(len(result.failures), 1)
        self.assertIn("deliberate assertion after acquisition", result.failures[0][1])
        self.assertEqual(checked, [True])


if __name__ == "__main__":
    unittest.main()
