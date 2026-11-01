"""Real-filesystem lifecycle checks; run with python3 scripts/tests/ui-test-runtime.test.py."""

import importlib.util
from pathlib import Path
import tempfile
import unittest
import uuid


SCRIPT = Path(__file__).resolve().parents[1] / "ui-test-runtime.py"
SPEC = importlib.util.spec_from_file_location("ui_test_runtime", SCRIPT)
runtime = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runtime)
FILENAMES = ("landscape-3x2.png", "portrait-2x3.png", "orientation-1.tiff")


class RuntimeFixtureTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="picsee-runtime-test-")
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name).resolve()
        self.runtime_root = self.base / "runtime"
        self.run = self.runtime_root / "run-a"
        self.source = SCRIPT.parents[1] / "TestAssets" / "synthetic"

    def test_stage_preserves_all_image_bytes_and_unrelated_sibling(self):
        sibling = self.runtime_root / "other-run" / "keep.txt"
        sibling.parent.mkdir(parents=True)
        sibling.write_bytes(b"unrelated")
        fixtures = runtime.stage(self.run, self.source, self.runtime_root)
        self.assertEqual(fixtures, self.run / "fixtures")
        self.assertTrue(fixtures.is_dir(), "stage must create the actual fixture directory")
        self.assertEqual(sorted(path.name for path in fixtures.iterdir()), sorted(FILENAMES))
        for name in FILENAMES:
            self.assertEqual((fixtures / name).read_bytes(), (self.source / name).read_bytes())
        self.assertEqual(sibling.read_bytes(), b"unrelated")

    def test_stage_rejects_outside_or_runtime_root_before_writing(self):
        for candidate in (self.base / "outside", self.runtime_root):
            with self.subTest(candidate=candidate):
                with self.assertRaises(ValueError):
                    runtime.stage(candidate, self.source, self.runtime_root)
                self.assertFalse((candidate / "fixtures").exists())

    def test_stage_rejects_protected_output_even_with_explicit_runtime_root(self):
        for folder in ("Documents", "Desktop", "Downloads"):
            protected_root = Path.home() / folder / ("picsee-ui-refusal-" + uuid.uuid4().hex)
            with self.subTest(folder=folder):
                with self.assertRaises(ValueError):
                    runtime.stage(protected_root / "run", self.source, protected_root)
                self.assertFalse(protected_root.exists())

    def test_stage_rejects_symlink_run_and_symlink_runtime_root(self):
        external = self.base / "external"
        external.mkdir()
        self.runtime_root.mkdir()
        self.run.symlink_to(external, target_is_directory=True)
        with self.assertRaises(ValueError):
            runtime.stage(self.run, self.source, self.runtime_root)
        linked_root = self.base / "linked-runtime"
        linked_root.symlink_to(external, target_is_directory=True)
        with self.assertRaises(ValueError):
            runtime.stage(linked_root / "run", self.source, linked_root)
        self.assertEqual(list(external.iterdir()), [])

    def test_missing_source_rejected_before_creating_run(self):
        incomplete = self.base / "incomplete"
        incomplete.mkdir()
        (incomplete / FILENAMES[0]).write_bytes((self.source / FILENAMES[0]).read_bytes())
        with self.assertRaises((ValueError, FileNotFoundError)):
            runtime.stage(self.run, incomplete, self.runtime_root)
        self.assertFalse(self.run.exists())

    def test_cleanup_removes_only_staged_fixtures_is_idempotent_and_keeps_logs(self):
        fixtures = runtime.stage(self.run, self.source, self.runtime_root)
        self.assertTrue(fixtures.is_dir(), "cleanup must be checked against actual staged files")
        self.run.mkdir(parents=True, exist_ok=True)
        log = self.run / "run.log"
        log.write_bytes(b"keep evidence")
        sibling = self.runtime_root / "other-run"
        sibling.mkdir()
        (sibling / "keep.txt").write_bytes(b"keep sibling")
        runtime.cleanup(self.run, self.runtime_root)
        runtime.cleanup(self.run, self.runtime_root)
        self.assertFalse((self.run / "fixtures").exists())
        self.assertEqual(log.read_bytes(), b"keep evidence")
        self.assertEqual((sibling / "keep.txt").read_bytes(), b"keep sibling")

    def test_cleanup_refuses_unowned_directory_without_deleting_it(self):
        fixtures = self.run / "fixtures"
        fixtures.mkdir(parents=True)
        (fixtures / FILENAMES[0]).write_bytes(b"not ours")
        with self.assertRaises(ValueError):
            runtime.cleanup(self.run, self.runtime_root)
        self.assertEqual((fixtures / FILENAMES[0]).read_bytes(), b"not ours")

    def test_cleanup_rejects_symlink_before_removing_any_staged_file(self):
        fixtures = runtime.stage(self.run, self.source, self.runtime_root)
        # RED stub returns a path without staging; keep the failure a behavioral assertion.
        self.assertTrue(fixtures.is_dir(), "stage must create the actual fixture directory")
        original = fixtures / FILENAMES[1]
        original.unlink()
        external = self.base / "external.png"
        external.write_bytes(b"must survive")
        original.symlink_to(external)
        with self.assertRaises(ValueError):
            runtime.cleanup(self.run, self.runtime_root)
        self.assertTrue((fixtures / FILENAMES[0]).is_file())
        self.assertEqual(external.read_bytes(), b"must survive")


    def app_fixture(self, suffix=None):
        name = self.run.name + "-" + (suffix or str(uuid.uuid4()).upper())
        folder = self.base / "container-fixtures" / name
        folder.mkdir(parents=True)
        for file in FILENAMES: (folder / file).write_bytes(b"fixture image")
        state = folder / ".test-access" / "nested"
        state.mkdir(parents=True)
        (state / "test-bookmark.json").write_bytes(b"test state")
        self.run.mkdir(parents=True, exist_ok=True)
        with (self.run / "run-1.log").open("a") as stream:
            stream.write('Find "grid.sidebar.folder.' + name + '" Button\n')
        return folder

    def test_container_cleanup_removes_only_logged_uuid_fixtures_and_keeps_evidence(self):
        owned = self.app_fixture()
        unrelated = self.base / "container-fixtures" / (self.run.name + "-" + str(uuid.uuid4()))
        unrelated.mkdir(); (unrelated / "keep.txt").write_bytes(b"unlogged")
        log = (self.run / "run-1.log").read_bytes()
        removed = runtime.cleanup_app_fixtures(self.run, self.runtime_root, owned.parent)
        self.assertEqual(removed, [owned.name])
        self.assertFalse(owned.exists())
        self.assertEqual((unrelated / "keep.txt").read_bytes(), b"unlogged")
        self.assertEqual((self.run / "run-1.log").read_bytes(), log)
        self.assertEqual(runtime.cleanup_app_fixtures(self.run, self.runtime_root, owned.parent), [])

    def test_container_cleanup_refuses_nested_symlink_before_removing_images(self):
        owned = self.app_fixture()
        external = self.base / "user-file"; external.write_bytes(b"must survive")
        (owned / ".test-access" / "external").symlink_to(external)
        with self.assertRaises(ValueError):
            runtime.cleanup_app_fixtures(self.run, self.runtime_root, owned.parent)
        self.assertEqual(external.read_bytes(), b"must survive")
        self.assertTrue((owned / FILENAMES[0]).exists())

    def test_container_cleanup_refuses_unexpected_files_before_any_deletion(self):
        owned = self.app_fixture()
        (owned / "unrecognized.txt").write_bytes(b"keep")
        with self.assertRaises(ValueError):
            runtime.cleanup_app_fixtures(self.run, self.runtime_root, owned.parent)
        self.assertEqual((owned / "unrecognized.txt").read_bytes(), b"keep")
        self.assertTrue((owned / FILENAMES[0]).exists())

    def test_container_cleanup_rejects_symlinked_evidence_log(self):
        owned = self.app_fixture()
        log = self.run / "run-1.log"
        external = self.base / "outside-log"; log.rename(external); log.symlink_to(external)
        with self.assertRaises(ValueError):
            runtime.cleanup_app_fixtures(self.run, self.runtime_root, owned.parent)
        self.assertTrue(owned.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
