import os
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("rebase-ledger.sh")
# A stand-in for scripts/ledger/build.mjs: regenerates the HTML from the Markdown and supports --check.
STUB_BUILD = """import fs from 'node:fs';
const html = '<p>' + fs.readFileSync('docs/feature-ledger.md', 'utf8').trim() + '</p>\\n';
if (process.argv.includes('--check')) process.exit(fs.readFileSync('docs/feature-ledger.html', 'utf8') === html ? 0 : 1);
fs.writeFileSync('docs/feature-ledger.html', html);
"""


def git(cwd, *args, env=None):
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True, env=env).stdout


class RebaseLedgerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.origin, self.work = root / "origin", root / "work"
        self.env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.invalid",
                    "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.invalid"}
        self.origin.mkdir()
        git(self.origin, "init", "-q", "-b", "main", env=self.env)
        (self.origin / "scripts/ledger").mkdir(parents=True)
        (self.origin / "scripts/ledger/build.mjs").write_text(STUB_BUILD)
        (self.origin / "docs").mkdir()
        self.write(self.origin, "docs/feature-ledger.md", "base\n")
        self.write(self.origin, "docs/feature-ledger.html", "<p>base</p>\n")
        self.write(self.origin, "code.txt", "base\n")
        git(self.origin, "add", ".", env=self.env)
        git(self.origin, "commit", "-qm", "init", env=self.env)
        git(root, "clone", "-q", str(self.origin), str(self.work), env=self.env)
        git(self.work, "switch", "-qc", "topic", env=self.env)

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, repo, path, text):
        (repo / path).write_text(text)

    def commit(self, repo, message, **files):
        for path, text in files.items():
            self.write(repo, path, text)
        git(repo, "add", *files, env=self.env)
        git(repo, "commit", "-qm", message, env=self.env)

    def run_script(self):
        return subprocess.run(["zsh", str(SCRIPT), "origin/main"], cwd=self.work, capture_output=True, text=True,
                              env=self.env)

    def test_resolved_html_conflict_keeps_body_lines_starting_with_hash(self):
        self.commit(self.origin, "docs: main side", **{"docs/feature-ledger.html": "<p>main</p>\n"})
        message = "feat(grid): topic\n\n#123 P2-05 FOLDER-06\nsecond line\n\nImplemented-by: t"
        self.commit(self.work, message, **{"docs/feature-ledger.html": "<p>topic</p>\n", "code.txt": "topic\n"})

        result = self.run_script()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("DONE resolved", result.stdout)
        self.assertEqual(git(self.work, "log", "-1", "--format=%B").strip(), message)

    def test_conflict_outside_the_ledger_stops_with_the_rebase_in_progress(self):
        self.commit(self.origin, "fix: main side", **{"code.txt": "main\n"})
        self.commit(self.work, "fix: topic side", **{"code.txt": "topic\n"})

        result = self.run_script()

        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("STOP other conflict: code.txt", result.stdout)
        self.assertTrue((self.work / ".git/rebase-merge").is_dir())


class RebaseVerifyTests(unittest.TestCase):
    """rebase-verify.sh compares an audited range with its rebased range."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name)
        self.env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.invalid",
                    "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.invalid"}
        git(self.repo, "init", "-q", "-b", "main", env=self.env)
        (self.repo / "App").mkdir()
        (self.repo / "App/blob.bin").write_bytes(b"\x00original\xff")
        git(self.repo, "add", "App/blob.bin", env=self.env)
        self.commit("init", **{"App/a.swift": "a\n", "App/b.swift": "b\n", "notes.md": "n\n"})
        self.old_base = self.head()
        self.commit("feat: topic\n\n#7 P1-01 VIEW-01", **{"App/a.swift": "a2\n"})
        self.old_head = self.head()
        git(self.repo, "switch", "-qc", "rebased", self.old_base, env=self.env)
        self.commit("docs: main moved", **{"notes.md": "n2\n", "App/b.swift": "b2\n"})
        self.new_base = self.head()

    def tearDown(self):
        self.tmp.cleanup()

    def head(self):
        return git(self.repo, "rev-parse", "HEAD").strip()

    def commit(self, message, **files):
        for path, text in files.items():
            (self.repo / path).write_text(text)
        git(self.repo, "add", *files, env=self.env)
        git(self.repo, "commit", "-qm", message, env=self.env)

    def verify(self):
        return subprocess.run(["zsh", str(Path(__file__).with_name("rebase-verify.sh")), self.old_base, self.old_head,
                               self.new_base, self.head()], cwd=self.repo, capture_output=True, text=True)

    def test_same_patch_on_a_moved_base_passes(self):
        self.commit("feat: topic\n\n#7 P1-01 VIEW-01", **{"App/a.swift": "a2\n"})

        result = self.verify()

        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("MESSAGES same", result.stdout)
        self.assertIn("CODE same", result.stdout)

    def test_conflict_resolution_that_changes_code_exits_1(self):
        self.commit("feat: topic\n\n#7 P1-01 VIEW-01", **{"App/a.swift": "a3\n"})

        result = self.verify()

        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("CODE differ", result.stdout)

    def test_app_tests_only_difference_exits_1(self):
        (self.repo / "AppTests").mkdir()
        self.commit("feat: topic\n\n#7 P1-01 VIEW-01", **{"App/a.swift": "a2\n", "AppTests/AppTests.swift": "test\n"})

        result = self.verify()

        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("CODE differ", result.stdout)

    def test_ui_tests_only_difference_exits_1(self):
        (self.repo / "UITests").mkdir()
        self.commit("feat: topic\n\n#7 P1-01 VIEW-01", **{"App/a.swift": "a2\n", "UITests/UITests.swift": "test\n"})

        result = self.verify()

        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("CODE differ", result.stdout)

    def test_dropped_hash_line_exits_2(self):
        self.commit("feat: topic", **{"App/a.swift": "a2\n"})

        result = self.verify()

        self.assertEqual(result.returncode, 2, result.stdout)
        self.assertIn("MESSAGES differ", result.stdout)

    def test_test_and_tooling_only_patches_same_or_different(self):
        for path in ("AppTests/Only.swift", "UITests/Only.swift", "scripts/check.sh", ".github/workflows/check.yml"):
            for same in (True, False):
                with self.subTest(path=path, same=same):
                    git(self.repo, "switch", "--detach", "-q", self.old_base, env=self.env)
                    (self.repo / path).parent.mkdir(parents=True, exist_ok=True)
                    self.commit("test: patch", **{path: "old patch\n"})
                    self.old_head = self.head()
                    git(self.repo, "switch", "--detach", "-q", self.new_base, env=self.env)
                    (self.repo / path).parent.mkdir(parents=True, exist_ok=True)
                    self.commit("test: patch", **{path: "old patch\n" if same else "changed patch\n"})
                    result = self.verify()
                    self.assertEqual(result.returncode, 0 if same else 1, result.stdout + result.stderr)
                    self.assertIn("CODE same" if same else "CODE differ", result.stdout)
                    self.assertNotIn("da39a3ee5e6b4b0d3255bfef95601890afd80709", result.stdout)

    def test_empty_input_on_either_side_fails_loudly(self):
        script = str(Path(__file__).with_name("rebase-verify.sh"))
        for old_empty, new_empty in ((True, True), (True, False), (False, True)):
            with self.subTest(old_empty=old_empty, new_empty=new_empty):
                result = subprocess.run(["zsh", script, self.old_base, self.old_base if old_empty else self.old_head,
                                         self.old_base, self.old_base if new_empty else self.old_head],
                                        cwd=self.repo, capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("empty", (result.stdout + result.stderr).lower())
                self.assertNotIn("CODE same", result.stdout)
                self.assertNotIn("da39a3ee", result.stdout)

    def test_full_patch_identity_mutations_differ(self):
        for mutation in ("rename", "deletion", "chmod", "binary", "different-path",
                         "package-lock.json", "design/state.html", "--flag", "++flag"):
            with self.subTest(mutation=mutation):
                git(self.repo, "switch", "--detach", "-q", self.new_base, env=self.env)
                if mutation == "different-path":
                    (self.repo / "App/other.swift").write_text("a2\n")
                else:
                    (self.repo / "App/a.swift").write_text("a2\n")
                if mutation == "rename":
                    git(self.repo, "mv", "App/b.swift", "App/c.swift", env=self.env)
                elif mutation == "deletion":
                    git(self.repo, "rm", "App/b.swift", env=self.env)
                elif mutation == "chmod":
                    (self.repo / "App/b.swift").chmod(0o755)
                elif mutation == "binary":
                    (self.repo / "App/blob.bin").write_bytes(b"\x00changed\xff")
                elif mutation in ("--flag", "++flag"):
                    with (self.repo / "App/a.swift").open("a") as f:
                        f.write(mutation + "\n")
                elif mutation in ("package-lock.json", "design/state.html"):
                    path = self.repo / mutation
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text("changed\n")
                git(self.repo, "add", "-A", env=self.env)
                git(self.repo, "commit", "-qm", "feat: topic\n\n#7 P1-01 VIEW-01", env=self.env)
                result = self.verify()
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn("CODE differ", result.stdout)

    def test_identical_edit_in_a_different_existing_path_differs(self):
        git(self.repo, "switch", "--detach", "-q", self.old_base, env=self.env)
        self.commit("base", **{"App/b.swift": "a\n"})
        self.old_base = self.head()
        self.new_base = self.old_base
        self.commit("edit", **{"App/a.swift": "a2\n"})
        self.old_head = self.head()
        git(self.repo, "switch", "--detach", "-q", self.new_base, env=self.env)
        self.commit("edit", **{"App/b.swift": "a2\n"})
        result = self.verify()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("CODE differ", result.stdout)

    def test_removing_double_minus_source_line_is_significant(self):
        git(self.repo, "switch", "--detach", "-q", self.old_base, env=self.env)
        self.commit("base", **{"App/a.swift": "a\n--flag\n"})
        self.old_base = self.new_base = self.head()
        self.commit("edit", **{"App/a.swift": "a2\n--flag\n"})
        self.old_head = self.head()
        git(self.repo, "switch", "--detach", "-q", self.new_base, env=self.env)
        self.commit("edit", **{"App/a.swift": "a2\n"})
        result = self.verify()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("CODE differ", result.stdout)

    def test_rebase_preserves_patch_with_shifted_hunks_and_blob_ids(self):
        git(self.repo, "switch", "--detach", "-q", self.old_base, env=self.env)
        self.commit("base", **{"App/a.swift": "before 1\nbefore 2\nbefore 3\nprefix\na\nsuffix\n"})
        self.old_base = self.head()
        self.commit("edit", **{"App/a.swift": "before 1\nbefore 2\nbefore 3\nprefix\na2\nsuffix\n"})
        self.old_head = self.head()
        git(self.repo, "switch", "--detach", "-q", self.old_base, env=self.env)
        self.commit("upstream", **{"App/a.swift": "upstream\nbefore 1\nbefore 2\nbefore 3\nprefix\na\nsuffix\n"})
        self.new_base = self.head()
        git(self.repo, "cherry-pick", self.old_head, env=self.env)
        result = self.verify()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("CODE same", result.stdout)

    def compare_edits(self, base, old_edit, new_edit):
        git(self.repo, "switch", "--detach", "-q", self.old_base, env=self.env)
        self.commit("base", **{"App/a.swift": base})
        self.old_base = self.new_base = self.head()
        self.commit("edit", **{"App/a.swift": old_edit})
        self.old_head = self.head()
        git(self.repo, "switch", "--detach", "-q", self.new_base, env=self.env)
        self.commit("edit", **{"App/a.swift": new_edit})
        return self.verify()

    def test_identical_u3_context_in_different_blocks_differs(self):
        body = "context\n" * 5 + "target\n" + "after\n" * 5
        base = "first\n" + body + "second\n" + body
        first_edit = base.replace("target\n", "edited\n", 1)
        second_edit = base[:base.index("second\n")] + base[base.index("second\n"):].replace(
            "target\n", "edited\n", 1)
        result = self.compare_edits(base, first_edit, second_edit)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("MESSAGES same", result.stdout)
        self.assertIn("CODE differ", result.stdout)
        self.assertIn("replayed tree differs", result.stdout)
        self.assertNotRegex(result.stdout, r"CODE differ ([0-9a-f]+) -> \1")

    def test_helper_git_failure_is_concise(self):
        result = subprocess.run(["python3", str(Path(__file__).with_name("rebase-verify-tree.py")),
                                 str(self.repo), "invalid-ref", self.old_head, self.new_base, self.head()],
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("rebase-verify:", result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def test_repeated_context_locations_survive_distant_upstream_shifts(self):
        initial_base = self.old_base
        for delete_prefix in (False, True):
            with self.subTest(delete_prefix=delete_prefix):
                self.old_base = initial_base
                git(self.repo, "switch", "--detach", "-q", self.old_base, env=self.env)
                prefix = "".join(f"prefix {i}\n" for i in range(1, 31))
                body = "context\n" * 5 + "target\n" + "after\n" * 5
                blocks = "first\n" + body + "second\n" + body
                self.commit("base", **{"App/a.swift": prefix + blocks})
                self.old_base = self.head()
                self.commit("edit", **{"App/a.swift": (prefix + blocks).replace("target\n", "edited\n", 1)})
                self.old_head = self.head()
                git(self.repo, "switch", "--detach", "-q", self.old_base, env=self.env)
                shifted = ("" if delete_prefix else prefix + prefix) + blocks
                self.commit("upstream", **{"App/a.swift": shifted})
                self.new_base = self.head()
                git(self.repo, "cherry-pick", self.old_head, env=self.env)
                # Real index and unstaged work must survive comparison.
                (self.repo / "notes.md").write_text("staged scratch\n")
                git(self.repo, "add", "notes.md", env=self.env)
                (self.repo / "notes.md").write_text("unstaged scratch\n")
                before = (self.head(), git(self.repo, "diff", "--binary"),
                          git(self.repo, "diff", "--cached", "--binary"))
                result = self.verify()
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("CODE same", result.stdout)
                self.assertEqual(before, (self.head(), git(self.repo, "diff", "--binary"),
                                         git(self.repo, "diff", "--cached", "--binary")))
                git(self.repo, "restore", "--staged", "notes.md", env=self.env)
                git(self.repo, "restore", "notes.md", env=self.env)
                git(self.repo, "switch", "--detach", "-q", self.new_base, env=self.env)
                second = shifted.index("second\n")
                self.commit("edit", **{"App/a.swift": shifted[:second] + shifted[second:].replace(
                    "target\n", "edited\n", 1)})
                result = self.verify()
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn("CODE differ", result.stdout)

    def test_upstream_deleting_original_block_cannot_retarget_identical_block(self):
        git(self.repo, "switch", "--detach", "-q", self.old_base, env=self.env)
        body = "context\n" * 5 + "target\n" + "after\n" * 5
        base = "first\n" + body + "second\n" + body
        self.commit("base", **{"App/a.swift": base})
        self.old_base = self.head()
        self.commit("edit", **{"App/a.swift": base.replace("target\n", "edited\n", 1)})
        self.old_head = self.head()
        git(self.repo, "switch", "--detach", "-q", self.old_base, env=self.env)
        surviving = "second\n" + body
        self.commit("upstream", **{"App/a.swift": surviving})
        self.new_base = self.head()
        self.commit("edit", **{"App/a.swift": surviving.replace("target\n", "edited\n", 1)})
        result = self.verify()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("MESSAGES same", result.stdout)
        self.assertIn("CODE differ", result.stdout)

    def test_nearby_upstream_context_exact_replay_passes(self):
        git(self.repo, "switch", "--detach", "-q", self.old_base, env=self.env)
        base = "".join(f"line {i}\n" for i in range(1, 31))
        self.commit("base", **{"App/a.swift": base})
        self.old_base = self.head()
        self.commit("edit", **{"App/a.swift": base.replace("line 10\n", "edited 10\n")})
        self.old_head = self.head()
        git(self.repo, "switch", "--detach", "-q", self.old_base, env=self.env)
        self.commit("upstream", **{"App/a.swift": base.replace("line 8\n", "upstream 8\n")})
        self.new_base = self.head()
        git(self.repo, "cherry-pick", self.old_head, env=self.env)
        result = self.verify()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("MESSAGES same", result.stdout)
        self.assertIn("CODE same", result.stdout)

        # #449 expressly changes only the honest cherry-pick expectation above.
        self.commit("altered candidate", **{"App/a.swift": base.replace("line 8\n", "upstream 8\n").replace("line 10\n", "wrong 10\n")})
        result = self.verify()
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("CODE differ", result.stdout)

    def test_replacing_first_or_second_identical_line_differs(self):
        result = self.compare_edits("a\nmiddle\na\n", "b\nmiddle\na\n", "a\nmiddle\nb\n")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("MESSAGES same", result.stdout)
        self.assertIn("CODE differ", result.stdout)

    def test_inserting_same_return_at_different_locations_differs(self):
        lines = [f"line {i}\n" for i in range(1, 41)]
        result = self.compare_edits("".join(lines), "".join(lines[:5] + ["return\n"] + lines[5:]),
                                    "".join(lines[:30] + ["return\n"] + lines[30:]))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("MESSAGES same", result.stdout)
        self.assertIn("CODE differ", result.stdout)

    def test_deleting_first_or_last_identical_line_differs(self):
        result = self.compare_edits("}\nmiddle\n}\n", "middle\n}\n", "}\nmiddle\n")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("MESSAGES same", result.stdout)
        self.assertIn("CODE differ", result.stdout)

    def test_function_suffix_context_distinguishes_identical_nearby_lines(self):
        body = "    context\n" * 5 + "    return old\n" + "    context\n" * 5
        base = "func first() {\n" + body + "}\nfunc second() {\n" + body + "}\n"
        result = self.compare_edits(base, base.replace("    return old", "    return new", 1),
                                    base[:base.index("func second")] +
                                    base[base.index("func second"):].replace("    return old", "    return new", 1))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("CODE differ", result.stdout)

    def test_rebase_preserves_patch_when_distant_hunk_in_same_file_changes(self):
        git(self.repo, "switch", "--detach", "-q", self.old_base, env=self.env)
        base = "".join(f"line {i}\n" for i in range(1, 61))
        self.commit("base", **{"App/a.swift": base})
        self.old_base = self.head()
        self.commit("edit", **{"App/a.swift": base.replace("line 10\n", "edited 10\n")})
        self.old_head = self.head()
        git(self.repo, "switch", "--detach", "-q", self.old_base, env=self.env)
        self.commit("upstream", **{"App/a.swift": base.replace("line 50\n", "upstream 50\n")})
        self.new_base = self.head()
        git(self.repo, "cherry-pick", self.old_head, env=self.env)
        result = self.verify()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("MESSAGES same", result.stdout)
        self.assertIn("CODE same", result.stdout)

    def test_subdirectory_invocation_compares_the_whole_repository(self):
        git(self.repo, "switch", "--detach", "-q", self.old_base, env=self.env)
        (self.repo / "sub").mkdir()
        self.commit("base", **{"sub/s.txt": "base\n"})
        self.old_base = self.new_base = self.head()
        self.commit("edit", **{"sub/s.txt": "same\n", "App/a.swift": "old edit\n"})
        self.old_head = self.head()
        git(self.repo, "switch", "--detach", "-q", self.new_base, env=self.env)
        self.commit("edit", **{"sub/s.txt": "same\n", "App/a.swift": "new edit\n"})
        root = self.verify()
        sub = subprocess.run(["zsh", str(Path(__file__).with_name("rebase-verify.sh").resolve()),
                              self.old_base, self.old_head, self.new_base, self.head()],
                             cwd=self.repo / "sub", capture_output=True, text=True)
        self.assertEqual(root.returncode, 1, root.stdout + root.stderr)
        self.assertIn("CODE differ", root.stdout)
        self.assertEqual(sub.returncode, root.returncode, sub.stdout + sub.stderr)
        self.assertEqual(sub.stdout, root.stdout)

    def test_generated_ledger_is_excluded_and_ledger_only_is_empty(self):
        (self.repo / "docs").mkdir()
        self.commit("feat: topic\n\n#7 P1-01 VIEW-01", **{
            "App/a.swift": "a2\n", "docs/feature-ledger.md": "generated\n",
            "docs/feature-ledger.html": "generated html\n"})
        result = self.verify()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("CODE same", result.stdout)
        self.old_base = self.new_base = self.head()
        self.commit("ledger only", **{"docs/feature-ledger.md": "regenerated\n"})
        self.old_head = self.head()
        result = self.verify()
        self.assertEqual(result.returncode, 4, result.stdout + result.stderr)
        self.assertIn("empty", result.stderr)

    def test_unknown_commit_exits_3(self):
        result = subprocess.run(["zsh", str(Path(__file__).with_name("rebase-verify.sh")), "nope", "HEAD", "HEAD",
                                 "HEAD"], cwd=self.repo, capture_output=True, text=True)

        self.assertEqual(result.returncode, 3, result.stdout)


class OwnerGatesRefusalTests(unittest.TestCase):
    """owner-gates.sh must refuse rather than gate the wrong code; a full run is exercised on real heads."""

    def run_gates(self, worktree, sha):
        with tempfile.TemporaryDirectory() as out:
            result = subprocess.run(["zsh", str(Path(__file__).with_name("owner-gates.sh")), worktree, sha, "t"],
                                    capture_output=True, text=True, env={**os.environ, "PICSEE_GATES_OUT": out})
            return result.returncode, (Path(out) / "t-summary.txt").read_text()

    def test_unwritable_summary_refuses_before_running_lanes(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            (out / "t-summary.txt").mkdir()
            result = subprocess.run(["zsh", str(Path(__file__).with_name("owner-gates.sh")),
                                     str(Path(__file__).resolve().parent), "HEAD", "t", "HEAD"],
                                    env={**os.environ, "PICSEE_GATES_OUT": str(out)},
                                    capture_output=True, text=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("cannot write summary", result.stderr)
            self.assertNotIn("DONE", result.stdout)
            self.assertEqual(sorted(p.name for p in out.iterdir()), ["t-summary.txt"])

    def test_head_mismatch_writes_no_gate_results(self):
        rc, summary = self.run_gates(str(Path(__file__).resolve().parent), "0" * 40)

        self.assertEqual(rc, 2)
        self.assertEqual(summary.strip(), "head mismatch")

    def test_missing_worktree_is_refused(self):
        rc, summary = self.run_gates("/nonexistent-picsee-worktree", "HEAD")

        self.assertEqual(rc, 2)
        self.assertIn("no worktree", summary)

    def unclean_case(self, setup):
        """Run owner-gates on a fresh repo after setup(work, git_dir); return (rc, summary, out files)."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            work, out = root / "work", root / "out"
            work.mkdir()
            env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.invalid",
                   "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.invalid"}
            git(work, "init", "-q", "-b", "main", env=env)
            (work / "tracked.txt").write_text("base\n")
            git(work, "add", "tracked.txt", env=env)
            git(work, "-c", "core.hooksPath=/dev/null", "commit", "-qm", "fixture", env=env)
            setup(work, work / ".git")
            result = subprocess.run(["zsh", str(Path(__file__).with_name("owner-gates.sh")), str(work), "HEAD", "t", "HEAD"],
                                    capture_output=True, text=True, timeout=20,
                                    env={**env, "PICSEE_GATES_OUT": str(out)})
            summary = (out / "t-summary.txt").read_text()
            return result.returncode, summary, sorted(p.name for p in out.iterdir()), result

    def test_unclean_worktree_is_refused_before_any_lane(self):
        """Gates read the working tree: a dirty tree or an unfinished rebase/merge/cherry-pick is not the head."""
        def dirty(work, _):
            (work / "tracked.txt").write_text("edited\n")

        def staged(work, _):
            (work / "tracked.txt").write_text("staged\n")
            git(work, "add", "tracked.txt")

        def rebase(_, git_dir):
            (git_dir / "rebase-merge").mkdir()

        def rebase_apply(_, git_dir):
            (git_dir / "rebase-apply").mkdir()

        def merge(_, git_dir):
            (git_dir / "MERGE_HEAD").write_text("0" * 40 + "\n")

        def cherry_pick(_, git_dir):
            (git_dir / "CHERRY_PICK_HEAD").write_text("0" * 40 + "\n")

        for name, setup, reason in (("dirty", dirty, "tracked changes"), ("staged", staged, "tracked changes"),
                                    ("rebase", rebase, "rebase in progress"),
                                    ("rebase-apply", rebase_apply, "rebase in progress"),
                                    ("merge", merge, "merge in progress"),
                                    ("cherry-pick", cherry_pick, "cherry-pick in progress")):
            with self.subTest(name):
                rc, summary, files, result = self.unclean_case(setup)
                self.assertEqual(rc, 2, result.stdout + result.stderr)
                self.assertIn(reason, summary)
                self.assertIn(reason, result.stderr)
                self.assertNotIn("DONE", summary)
                self.assertNotIn("swift=", summary)
                self.assertEqual(files, ["t-summary.txt"])

    def test_untracked_files_do_not_block_a_clean_head(self):
        """Untracked build output (.build, node_modules) is not a tracked change."""
        def untracked(work, _):
            (work / "scratch.txt").write_text("untracked\n")
        rc, summary, _, result = self.unclean_case(untracked)
        self.assertNotIn("tracked changes", summary + result.stderr)
        self.assertIn("swift=", summary)


class OwnerGatesDesignTests(unittest.TestCase):
    """Exercise the real shell orchestration with cheap external-command fixtures."""

    def test_design_status_log_and_completion_order(self):
        for design_rc in (0, 7):
            with self.subTest(design_rc=design_rc), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                work, home, out, tools = (root / name for name in ("work", "home", "out", "tools"))
                commands = home / ".picsee/tools/xcodegen/bin"
                for directory in (work, out, tools, commands, work / "scripts/tdd", work / "coverage"):
                    directory.mkdir(parents=True, exist_ok=True)
                env = {**os.environ, "HOME": str(home), "PICSEE_GATES_OUT": str(out),
                       "DESIGN_RC": str(design_rc), "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.invalid",
                       "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.invalid"}
                git(work, "init", "-q", "-b", "main", env=env)
                git(work, "-c", "core.hooksPath=/dev/null", "commit", "--allow-empty", "-qm", "fixture", env=env)
                source = Path(__file__).parent
                for name in ("owner-gates.sh",):
                    (tools / name).write_text((source / name).read_text())

                def executable(path, text):
                    path.write_text("#!/bin/sh\n" + text)
                    path.chmod(0o755)

                for folder in ("agents", "tdd", "ledger", "name-checks", "ci"):
                    directory = work / "scripts" / folder
                    directory.mkdir(exist_ok=True)
                    (directory / "fixture.test.mjs").write_text("// command fixture\n")
                (work / "scripts/ci/name-checks-ci.test.mjs").write_text("// command fixture\n")
                (work / "node_modules").mkdir()
                executable(work / "scripts/heavy-lock.sh", 'export TEST_HEAVY_HELD=1\nexec "$@"\n')
                (work / "scripts/tdd/swift-lcov.sh").write_text("echo 'LF:1\nLH:1\nFNF:1\nFNH:1' > coverage/lcov.info\n")
                for command in ("xcodegen", "xcodebuild", "node"):
                    executable(commands / command, "exit 0\n")
                executable(commands / "swift", "echo 'Test run with 1 tests passed'\n")
                executable(commands / "npm", '''
[ "$*" = 'run design:check' ] || exit 90
[ "$TEST_HEAVY_HELD" = 1 ] || exit 91
grep -q '^DONE$' "$PICSEE_GATES_OUT/t-summary.txt" && exit 92
echo "design fixture rc=$DESIGN_RC"
exit "$DESIGN_RC"
''')
                result = subprocess.run(["zsh", str(tools / "owner-gates.sh"), str(work), "HEAD", "t", "HEAD"],
                                        capture_output=True, text=True, env=env, timeout=20)
                self.assertEqual(result.returncode, 0 if design_rc == 0 else 1, result.stdout + result.stderr)
                summary = (out / "t-summary.txt").read_text().splitlines()
                self.assertIn(f"design={design_rc}", summary)
                self.assertEqual(summary[-1], "DONE")
                self.assertLess(summary.index(f"design={design_rc}"), summary.index("DONE"))
                self.assertEqual((out / "t-design.log").read_text().strip(), f"design fixture rc={design_rc}")



class OwnerGatesExitTests(unittest.TestCase):
    """The completed summary and exit status must agree for every lane."""

    def test_each_lane_failure_and_pass_fail_pass_reruns(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            work, out, commands, tools = (root / name for name in ("work", "out", "bin", "tools"))
            for path in (work, out, commands, tools, work / "scripts/tdd", work / "coverage"):
                path.mkdir(parents=True, exist_ok=True)
            env = {**os.environ, "HOME": str(root / "home"), "PATH": str(commands) + ":" + os.environ["PATH"],
                   "PICSEE_GATES_OUT": str(out), "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.invalid",
                   "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.invalid"}
            # owner-gates prepends this directory, before any installed native tools.
            first = root / "home/.picsee/tools/xcodegen/bin"
            first.mkdir(parents=True)
            git(work, "init", "-q", "-b", "main", env=env)
            git(work, "-c", "core.hooksPath=/dev/null", "commit", "--allow-empty", "-qm", "fixture", env=env)
            for name in ("owner-gates.sh", "lcov-total.py"):
                (tools / name).write_text(Path(__file__).with_name(name).read_text())
            def executable(path, text):
                path.write_text("#!/bin/sh\n" + text)
                path.chmod(0o755)
            executable(work / "scripts/heavy-lock.sh", 'exec "$@"\n')
            for directory in ("agents", "tdd", "ledger", "name-checks", "ci"):
                folder = work / "scripts" / directory
                folder.mkdir(exist_ok=True)
                (folder / "fixture.test.mjs").write_text("// fixture\n")
            (work / "scripts/ci/name-checks-ci.test.mjs").write_text("// fixture\n")
            (work / "node_modules").mkdir()
            for command, lane in (("swift", "swift"), ("xcodegen", "xcodegen"), ("xcodebuild", "xcodebuild"),
                                  ("npm", "design"), ("node", "node")):
                executable(first / command, f'''lane={lane}
[ "$lane" = node ] && [ "$1" = scripts/ci/package-coverage-local.mjs ] && lane=lcov
[ "$lane" = node ] && [ "$1" = scripts/tdd/unit-lane.mjs ] && lane=swift
[ "$lane" = node ] && [ "$1" != --test ] && lane=ledger
[ "$FAIL_LANE" = "$lane" ] && exit 7
[ "$FAIL_LANE" = missing ] && [ "$lane" = xcodegen ] && exec picsee_missing_tool_423
[ "$lane" = swift ] && echo 'Test run with 1 tests passed'
exit 0
''')
            real_git = subprocess.check_output(["which", "git"], text=True).strip()
            executable(first / "git", f'''[ "$FAIL_LANE" = diffcheck ] && [ "$1" = diff ] && exit 7
exec "{real_git}" "$@"
''')
            # All child lanes pass, but summary creation must still fail closed.
            blocked = out / "blocked-summary.txt"
            blocked.mkdir()
            result = subprocess.run(["zsh", str(tools / "owner-gates.sh"), str(work), "HEAD", "blocked", "HEAD"],
                                    env={**env, "FAIL_LANE": ""}, capture_output=True, text=True, timeout=20)
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("cannot write summary", result.stderr)
            self.assertEqual(list(out.iterdir()), [blocked])
            lanes = ("swift", "lcov", "xcodegen", "xcodebuild", "node", "ledger", "diffcheck", "design")
            for fail in ("", *lanes, "missing", ""):
                with self.subTest(fail=fail):
                    result = subprocess.run(["zsh", str(tools / "owner-gates.sh"), str(work), "HEAD", "t", "HEAD"],
                                            env={**env, "FAIL_LANE": fail}, capture_output=True, text=True, timeout=20)
                    summary = (out / "t-summary.txt").read_text().splitlines()
                    statuses = [line for line in summary if line.split("=")[0] in lanes]
                    expected = {lane: 0 for lane in lanes}
                    if fail:
                        expected[{"missing": "xcodegen"}.get(fail, fail)] = 127 if fail == "missing" else 7
                    if fail == "swift":
                        expected["lcov"] = 1  # coverage is never evaluated after a failed Swift run
                    self.assertEqual(statuses, [f"{lane}={expected[lane]}" for lane in lanes])
                    self.assertEqual(result.returncode, 1 if fail else 0, result.stdout + result.stderr)
                    self.assertEqual(summary[-1], "DONE")
                    for line in statuses:
                        self.assertIn(line, result.stdout)


class ResolvePart3Tests(unittest.TestCase):
    """Part 3 conflicts append the branch's suffix over the merge base; main's text is never dropped (#243 near-miss)."""

    def run_resolve(self, text, base=None):
        import importlib.util
        spec = importlib.util.spec_from_file_location('resolve_part3', Path(__file__).with_name('resolve_part3.py'))
        mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
        return mod.resolve(text, base)

    def conflict(self, head, theirs, nl='\n'):
        return nl.join(['<<<<<<< HEAD', head, '=======', theirs, '>>>>>>> x', ''])

    def test_appends_branch_suffix_and_keeps_main_note_and_newer_date(self):
        base = '| 网格 | 2026-10-26 | g | 主线注一。 |\n'
        text = self.conflict('| 网格 | 2026-10-28 | g | 主线注一。 主线注二。 |', '| 网格 | 2026-10-27 | g | 主线注一。 分支注。 |')
        out, ok = self.run_resolve(text, base)
        self.assertTrue(ok)
        self.assertEqual(out, '| 网格 | 2026-10-28 | g | 主线注一。 主线注二。 分支注。 |\n')

    def test_repeated_stock_sentences_in_branch_entry_are_kept(self):
        # audit confirm N1: 「这次没有检查真机。」 and 「无新增提议。」 recur across entries; none may be dropped
        base = '| 甲 | 2026-10-26 | g | 甲（a..b）：OPEN-01 未变。无新增提议。 |\n'
        head = '| 甲 | 2026-10-28 | g | 甲（a..b）：OPEN-01 未变。无新增提议。 丙（e..f）：这次没有检查真机。待 owner 确认。 |'
        theirs = '| 甲 | 2026-10-28 | g | 甲（a..b）：OPEN-01 未变。无新增提议。 乙（c..d）：OPEN-02 升为 Partial。待 owner 确认。这次没有检查真机。无新增提议。 |'
        out, ok = self.run_resolve(self.conflict(head, theirs), base)
        self.assertTrue(ok)
        self.assertIn('丙（e..f）：这次没有检查真机。待 owner 确认。 乙（c..d）：OPEN-02 升为 Partial。待 owner 确认。这次没有检查真机。无新增提议。 |', out)

    def test_newer_branch_review_date_and_reviewer_win(self):
        base = '| 网格 | 2026-10-19 | g | A。 |\n'
        out, ok = self.run_resolve(self.conflict('| 网格 | 2026-10-20 | g | A。 |', '| 网格 | 2026-10-29 | h | A。 B。 |'), base)
        self.assertEqual(out, '| 网格 | 2026-10-29 | h | A。 B。 |\n')

    def test_suffix_main_already_holds_is_not_doubled(self):
        base = '| 甲 | 2026-10-26 | g | A。 |\n'
        out, ok = self.run_resolve(self.conflict('| 甲 | 2026-10-28 | g | A。 B。 C。 |', '| 甲 | 2026-10-28 | g | A。 B。 |'), base)
        self.assertEqual(out, '| 甲 | 2026-10-28 | g | A。 B。 C。 |\n')

    def test_branch_that_edited_base_text_is_unresolved(self):
        base = '| 甲 | 2026-10-26 | g | 甲：OPEN-01 限制未变。 |\n'
        text = self.conflict('| 甲 | 2026-10-28 | g | 甲：OPEN-01 限制未变。 X。 |', '| 甲 | 2026-10-28 | g | 甲：OPEN-01 限制已更新。 |')
        out, ok = self.run_resolve(text, base)
        self.assertFalse(ok)
        self.assertIn('<<<<<<<', out)

    def test_without_merge_base_a_differing_row_is_unresolved(self):
        out, ok = self.run_resolve(self.conflict('| 甲 | 2026-10-28 | g | A。 |', '| 甲 | 2026-10-28 | g | A。 B。 |'))
        self.assertFalse(ok)

    def test_cell_count_mismatch_is_unresolved(self):
        # audit confirm N2: a pipe in a note must not silently drop the branch row
        base = '| 甲 | 2026-10-26 | g | A。 |\n'
        out, ok = self.run_resolve(self.conflict('| 甲 | 2026-10-28 | g | A。 |', '| 甲 | 2026-10-28 | g | A。 B \\| C。 |'), base)
        self.assertFalse(ok)

    def test_branch_only_row_is_kept(self):
        text = self.conflict('| 甲 | 2026-10-28 | g | 甲注。 |', '| 甲 | 2026-10-28 | g | 甲注。 |\n| 乙 | 2026-10-28 | g | 乙注。 |')
        out, ok = self.run_resolve(text)
        self.assertTrue(ok)
        self.assertEqual(out, '| 甲 | 2026-10-28 | g | 甲注。 |\n| 乙 | 2026-10-28 | g | 乙注。 |\n')

    def test_unterminated_branch_tail_and_crlf_are_preserved(self):
        base = '| 甲 | 2026-10-26 | g | A。 |\r\n'
        text = self.conflict('| 甲 | 2026-10-28 | g | A。 |', '| 甲 | 2026-10-28 | g | A。B 待 owner |', '\r\n')
        out, ok = self.run_resolve(text, base)
        self.assertEqual(out, '| 甲 | 2026-10-28 | g | A。B 待 owner |\r\n')

    def test_non_row_conflict_is_left_unresolved(self):
        out, ok = self.run_resolve(self.conflict('prose A', 'prose B'))
        self.assertFalse(ok)
        self.assertIn('<<<<<<<', out)


LIVE_RESET_SCREEN = Path(__file__).with_name("fixtures").joinpath("reset-fresh-codex.txt").read_text()


class ResetTests(unittest.TestCase):
    """Run the real reset CLI through chooser/startup/context transitions."""

    SUCCESS = ("reset fixture-agent old_session=old-session Context 0% used "
               "(verify the session id changes after the next turn)\n")

    def run_reset(self, *, delay=0, context="Context 0% used", status="idle", chooser=True, deadline="2",
                  poll="0.01", prefix="", startup=">_ OpenAI Codex (v0.166.0)", timer_var=None, old_context="",
                  ready_boundary=">_ OpenAI Codex (v0.166.0)", locale=None, session_before="", session_after="", session_delay=0, pane_height=0):
        import time

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            herdr = root / "herdr"
            herdr.write_text('''#!/bin/sh
case "$1 $2" in
  'agent get')
    printf '{"agent_status":"%s","value":"old-session"}\\n' "$RESET_STATUS"
    ;;
  'pane get')
    count=0
    [ ! -f "$RESET_STATE/gets" ] || count=$(cat "$RESET_STATE/gets")
    echo $((count + 1)) > "$RESET_STATE/gets"
    session=$RESET_SESSION_BEFORE
    if [ -f "$RESET_STATE/enters" ] && [ "$(cat "$RESET_STATE/enters")" -ge 2 ] &&
       [ "$(cat "$RESET_STATE/reads")" -ge "$RESET_SESSION_DELAY" ]; then
      session=$RESET_SESSION_AFTER
    fi
    printf '{"result":{"pane":{"other":{"value":"wrong-id"},"agent_session":{"value":"%s"}}}}\\n' "$session"
    ;;
  'pane send-text')
    echo sent >> "$RESET_STATE/sends"
    echo 0 > "$RESET_STATE/enters"
    echo 0 > "$RESET_STATE/reads"
    ;;
  'pane send-keys')
    echo sent >> "$RESET_STATE/sends"
    n=$(cat "$RESET_STATE/enters")
    echo $((n + 1)) > "$RESET_STATE/enters"
    ;;
  'pane read')
    if [ ! -f "$RESET_STATE/enters" ]; then
      printf '%s\\n' "$RESET_OLD_CONTEXT"
      exit 0
    fi
    n=$(cat "$RESET_STATE/enters")
    if [ "$RESET_CHOOSER" = 0 ]; then
      echo 'ordinary pane, no chooser'
    elif [ "$n" -lt 2 ]; then
      echo 'Where should the new conversation run?'
    else
      n=$(cat "$RESET_STATE/reads")
      echo $((n + 1)) > "$RESET_STATE/reads"
      # A recent snapshot defaults to the pane height unless --lines expands it.
      limit=$RESET_PANE_HEIGHT
      shift 3
      while [ "$#" -gt 0 ]; do
        if [ "$1" = --lines ]; then limit=$2; shift; fi
        shift
      done
      if [ "$limit" -gt 0 ]; then
        exec 3>&1
        exec > "$RESET_STATE/screen"
        trap 'tail -n "$limit" "$RESET_STATE/screen" >&3' EXIT
      fi
      printf '%s\\n' "$RESET_PREFIX"
      if [ "$n" -lt "$RESET_DELAY" ] || [ -z "$RESET_CONTEXT" ]; then
        printf '%s\\n' "$RESET_STARTUP"
      else
        printf '%s\\n' "$RESET_READY_BOUNDARY"
        printf '%s\\n' "$RESET_CONTEXT"
      fi
    fi
    ;;
  *) exit 90 ;;
esac
''')
            herdr.chmod(0o755)
            # Bypass external sleeps; deadline still uses the real monotonic shell timer.
            sleep = root / "sleep"
            sleep.write_text("#!/bin/sh\nexit 0\n")
            sleep.chmod(0o755)
            env = {**os.environ, "PATH": str(root) + os.pathsep + os.environ["PATH"],
                   "RESET_SESSION_BEFORE": session_before, "RESET_SESSION_AFTER": session_after,
                   "RESET_SESSION_DELAY": str(session_delay),
                   "RESET_STATE": str(root), "RESET_STATUS": status, "RESET_CHOOSER": str(int(chooser)),
                   "RESET_DELAY": str(delay), "RESET_CONTEXT": context, "RESET_PANE_HEIGHT": str(pane_height),
                   "RESET_PREFIX": prefix, "RESET_STARTUP": startup,
                   "RESET_OLD_CONTEXT": old_context, "RESET_READY_BOUNDARY": ready_boundary,
                   "PICSEE_RESET_CONTEXT_SECS": deadline, "PICSEE_RESET_POLL_SECS": poll}
            if locale:
                env["LC_ALL"] = locale
            if timer_var:
                env[timer_var] = deadline
                if timer_var == "PICSEE_RESET_POLL_SECS":
                    env["PICSEE_RESET_CONTEXT_SECS"] = "2"
            started = time.monotonic()
            result = subprocess.run(["zsh", str(Path(__file__).with_name("reset.sh")),
                                     "fixture-agent", "fixture-pane"],
                                    capture_output=True, text=True, env=env, timeout=5)
            result.pane_sends = (root / "sends").read_text() if (root / "sends").exists() else ""
            result.pane_gets = int((root / "gets").read_text()) if (root / "gets").exists() else 0
            return result, time.monotonic() - started

    def test_real_saved_screen_with_missing_session_id_succeeds(self):
        result, _ = self.run_reset(context=LIVE_RESET_SCREEN, ready_boundary="", locale="C")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, self.SUCCESS)

    def test_header_over_prior_transcript_never_proves_freshness(self):
        transcripts = ("› hello\n• Hello!", "› hello", "• Ran a tool", "└ tool output",
                       "Previous model reply", "```\nold reply\n```", "> quoted reply",
                       "Tip: old model reply", "› Ask Codex to do anything else", "/tmp/old-model-output")
        for transcript in transcripts:
            for percent in (0, 3):
                with self.subTest(transcript=transcript, percent=percent):
                    screen = LIVE_RESET_SCREEN.replace("› Ask Codex to do anything",
                                                      transcript + "\n› Ask Codex to do anything")
                    screen = screen.replace("Context 0%", f"Context {percent}%")
                    result, _ = self.run_reset(context=screen, ready_boundary="", startup="",
                                               deadline="0.1", locale="C",
                                               session_before="old-session", session_after="old-session")
                    self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                    self.assertEqual(result.stdout, self.NO_BOUNDARY)

    def test_transcript_before_bottommost_footer_revokes_header_proof(self):
        for percent in (0, 3):
            with self.subTest(percent=percent):
                screen = LIVE_RESET_SCREEN + f"› hello\n• Hello!\n› Ask Codex to do anything\nContext {percent}% used"
                result, _ = self.run_reset(context=screen, ready_boundary="", startup="", deadline="0.1")
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertEqual(result.stdout, self.NO_BOUNDARY)

    def test_short_old_nonzero_screen_waits_for_real_fresh_screen(self):
        old = LIVE_RESET_SCREEN.replace("› Ask Codex to do anything", "› hello\n• Hello!")
        old = old.replace("Context 0%", "Context 3%")
        result, _ = self.run_reset(delay=1, startup=old, context=LIVE_RESET_SCREEN,
                                   ready_boundary="", session_before="old-session", session_after="old-session")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, self.SUCCESS)
        self.assertGreaterEqual(result.pane_gets, 3)

    def test_empty_welcome_screen_allows_known_tips_and_box_art(self):
        screen = LIVE_RESET_SCREEN.replace("› Ask Codex to do anything",
            "╭──╮\n│  │\n╰──╯\n  Tip: Use /help to see available commands.\n› Ask Codex to do anything")
        result, _ = self.run_reset(context=screen, ready_boundary="", locale="C")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, self.SUCCESS)

    def test_changed_session_id_proves_markerless_footer(self):
        result, _ = self.run_reset(session_before="old-session", session_after="new-session", ready_boundary="")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, self.SUCCESS)

    def test_unchanged_session_id_accepts_real_saved_screen(self):
        result, _ = self.run_reset(session_before="old-session", session_after="old-session",
                                   context=LIVE_RESET_SCREEN, ready_boundary="", locale="C")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, self.SUCCESS)

    def test_unchanged_session_id_rejects_stale_screen_without_header(self):
        for screen in ("Context 0% used", "/new\nContext 0% used", "Starting MCP servers\nContext 0% used"):
            with self.subTest(screen=screen):
                result, _ = self.run_reset(session_before="old-session", session_after="old-session",
                                           context=screen, ready_boundary="", deadline="0.1")
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertEqual(result.stdout, self.NO_BOUNDARY)

    def test_session_id_change_is_polled_before_success(self):
        result, _ = self.run_reset(session_before="old-session", session_after="new-session", session_delay=2, ready_boundary="")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, self.SUCCESS)
        self.assertGreaterEqual(result.pane_gets, 4)

    def test_session_id_unavailable_on_either_side_uses_header(self):
        for before, after in (("", "new-session"), ("old-session", "")):
            with self.subTest(before=before, after=after):
                result, _ = self.run_reset(session_before=before, session_after=after,
                                           context=LIVE_RESET_SCREEN, ready_boundary="")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(result.stdout, self.SUCCESS)

    def test_changed_session_still_requires_footer_and_rejects_nonzero(self):
        for context, expected in (("", "no context line after 0.1s"),
                                  ("Context 12% used", "Context 12% used after /new")):
            with self.subTest(context=context):
                result, _ = self.run_reset(session_before="old-session", session_after="new-session",
                                           context=context, ready_boundary="", startup="", deadline="0.1")
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertEqual(result.stdout, f"FAIL reset fixture-agent: {expected}\n")

    def test_real_status_line_needs_proof_and_rejects_nonzero(self):
        result, _ = self.run_reset(context=LIVE_RESET_SCREEN.replace("Context 0%", "Context 12%"),
                                   ready_boundary="", deadline="0.1")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(result.stdout, "FAIL reset fixture-agent: Context 12% used after /new\n")
        footer = LIVE_RESET_SCREEN.splitlines()[-2]
        result, _ = self.run_reset(context=footer, ready_boundary="", deadline="0.1")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(result.stdout, self.NO_BOUNDARY)

    def test_quoted_or_fenced_header_cannot_prove_reset(self):
        for header in ('> >_ OpenAI Codex (v0.166.0)', '" >_ OpenAI Codex (v0.166.0)"',
                       '```\n>_ OpenAI Codex (v0.166.0)\n```'):
            with self.subTest(header=header):
                result, _ = self.run_reset(context=header + "\nContext 0% used", ready_boundary="", deadline="0.1")
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertEqual(result.stdout, self.NO_BOUNDARY)

    def test_header_must_precede_footer_in_same_read(self):
        for delay, startup, context in ((0, "", "Context 0% used\n>_ OpenAI Codex (v0.166.0)"),
                                         (1, ">_ OpenAI Codex (v0.166.0)", "Context 0% used")):
            with self.subTest(delay=delay):
                result, _ = self.run_reset(delay=delay, startup=startup, context=context,
                                           ready_boundary="", deadline="0.1")
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertEqual(result.stdout, self.NO_BOUNDARY if delay == 0 else
                                 "FAIL reset fixture-agent: no context line after 0.1s\n")

    def test_changed_id_does_not_accept_footer_under_chooser(self):
        result, _ = self.run_reset(session_before="old-session", session_after="new-session",
                                   prefix="Where should the new conversation run?", ready_boundary="", deadline="0.1")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(result.stdout, "FAIL reset fixture-agent: no context line after 0.1s\n")

    def test_unchanged_session_id_without_header_waits_on_nonzero_footer(self):
        result, elapsed = self.run_reset(session_before="old-session", session_after="old-session",
                                         context="Context 12% used", ready_boundary="", deadline="0.1")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(result.stdout, self.NO_BOUNDARY)
        self.assertGreaterEqual(elapsed, 0.09)

    def test_quoted_or_fenced_decorated_footer_is_ignored(self):
        footer = LIVE_RESET_SCREEN.splitlines()[-2]
        for quoted in ('> ' + footer.strip(), '"' + footer.strip() + '"',
                       'The pane says ' + footer.strip(), '```\n' + footer + '\n```',
                       '~~~\n' + footer + '\n~~~'):
            with self.subTest(quoted=quoted):
                result, _ = self.run_reset(context=quoted, deadline="0.1")
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertEqual(result.stdout, self.NO_BOUNDARY)

    def test_unchanged_id_with_header_uses_bottommost_footer(self):
        for context in ("Context 12% used", "Context 0% used\nContext 12% used"):
            with self.subTest(context=context):
                result, _ = self.run_reset(session_before="old-session", session_after="old-session", context=context)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertEqual(result.stdout, "FAIL reset fixture-agent: Context 12% used after /new\n")

    def test_later_ordering_marker_requires_new_header(self):
        for marker in ("/new", "Starting MCP servers", "Where should the new conversation run?"):
            with self.subTest(marker=marker):
                result, _ = self.run_reset(context=marker + "\nContext 0% used", deadline="0.1")
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertEqual(result.stdout, "FAIL reset fixture-agent: no context line after 0.1s\n")

    def test_empty_startup_reads_preserve_success(self):
        for delay in (0, 1, 3, 12):
            with self.subTest(delay=delay):
                result, _ = self.run_reset(delay=delay)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(result.stdout, self.SUCCESS)

    def test_done_status_can_reset(self):
        result, _ = self.run_reset(status="done")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, self.SUCCESS)

    def test_missing_context_waits_for_and_names_timeout(self):
        result, elapsed = self.run_reset(context="", deadline="0.1")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(result.stdout, "FAIL reset fixture-agent: no context line after 0.1s\n")
        self.assertGreaterEqual(elapsed, 0.09)

    def test_invalid_timers_fail_before_any_pane_input(self):
        invalid = ("0", "-1", "abc", "", " ", "inf", "Inf", "nan", "NaN", "1e400",
                   "300.01", "999999999999999999999999999999", "1+1", "a[$(exit 91)]")
        for var in ("PICSEE_RESET_CONTEXT_SECS", "PICSEE_RESET_POLL_SECS"):
            for value in invalid:
                with self.subTest(var=var, value=value):
                    result, _ = self.run_reset(deadline=value, timer_var=var)
                    self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                    self.assertEqual(result.stdout, f"FAIL reset fixture-agent: invalid {var}={value}\n")
                    self.assertEqual(result.pane_sends, "")

    def test_positive_decimal_timer_boundaries(self):
        for var in ("PICSEE_RESET_CONTEXT_SECS", "PICSEE_RESET_POLL_SECS"):
            for value in ("0.01", "300"):
                with self.subTest(var=var, value=value):
                    result, _ = self.run_reset(deadline=value, timer_var=var)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertEqual(result.stdout, self.SUCCESS)

    def test_stale_zero_before_title_cannot_prove_fresh_screen(self):
        for marker in ("Where should the new conversation run?", "/new", "Starting MCP servers (3/4)"):
            with self.subTest(marker=marker):
                result, _ = self.run_reset(delay=3, context="Context 12% used", deadline="0.1",
                                           prefix=f"Context 0% used\n{marker}")
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertEqual(result.stdout, self.NO_BOUNDARY)

    def test_old_nonzero_above_title_cannot_prove_fresh_screen(self):
        result, _ = self.run_reset(prefix="Context 12% used\n/new", deadline="0.1")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(result.stdout, self.NO_BOUNDARY)

    def test_bottommost_new_footer_decides(self):
        result, _ = self.run_reset(context="Context 0% used\nContext 12% used")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(result.stdout, "FAIL reset fixture-agent: Context 12% used after /new\n")

    def test_quoted_context_in_body_is_ignored(self):
        for quote in ('The issue says "Context 0% used" during startup.', '"Context 0% used"',
                      '> Context 0% used'):
            with self.subTest(quote=quote):
                result, _ = self.run_reset(context="", deadline="0.1", startup=f">_ OpenAI Codex (v0.166.0)\n{quote}")
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertEqual(result.stdout, self.NO_BOUNDARY)

    def test_markerless_stale_footer_cannot_succeed_early(self):
        result, _ = self.run_reset(old_context="Context 0% used", delay=3, deadline="0.1",
                                   startup="Context 0% used", context="Context 12% used", ready_boundary="")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(result.stdout, self.NO_BOUNDARY)

    NO_BOUNDARY = ("FAIL reset fixture-agent: no new-session boundary seen within 0.1s; "
                   "check the pane\n")

    def test_unchanged_markerless_zero_never_proves_reset(self):
        result, _ = self.run_reset(old_context="Context 0% used", deadline="0.1", ready_boundary="")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(result.stdout, self.NO_BOUNDARY)

    def test_blank_then_stale_zero_never_proves_reset(self):
        result, _ = self.run_reset(old_context="Context 0% used", delay=1, startup="", deadline="0.1",
                                   ready_boundary="")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(result.stdout, self.NO_BOUNDARY)

    def test_boundary_does_not_latch_across_reads(self):
        result, _ = self.run_reset(delay=1, startup="/new", deadline="0.1", ready_boundary="")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(result.stdout, self.NO_BOUNDARY)

    def test_footer_under_last_chooser_is_not_session_context(self):
        for context in ("Context 0% used", "Context 37% used"):
            with self.subTest(context=context):
                result, _ = self.run_reset(prefix="/new\nWhere should the new conversation run?",
                                           context=context, ready_boundary="", deadline="0.1")
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertEqual(result.stdout, self.NO_BOUNDARY)

    def test_chooser_footer_waits_for_started_session(self):
        result, _ = self.run_reset(delay=1, startup="Where should the new conversation run?\nContext 37% used")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, self.SUCCESS)

    def test_non_header_boundaries_never_prove_session_in_c_locale(self):
        for boundary in ("/new", "> /new", "❯ /new", "› /new", "Starting MCP servers (3/4)"):
            for context in ("Context 0% used", "Context 12% used"):
                with self.subTest(boundary=boundary, context=context):
                    result, _ = self.run_reset(ready_boundary=boundary, locale="C", context=context, deadline="0.1")
                    self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                    self.assertEqual(result.stdout, self.NO_BOUNDARY)

    def test_quoted_boundaries_never_prove_reset(self):
        for boundary in ('> /new', '> Starting MCP servers (3/4)',
                         '> Where should the new conversation run?', '"Starting MCP servers (3/4)"'):
            # > /new is a real Codex prompt; blockquoted startup/chooser text is not.
            if boundary == '> /new':
                continue
            with self.subTest(boundary=boundary):
                result, _ = self.run_reset(ready_boundary=boundary, deadline="0.1")
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertEqual(result.stdout, self.NO_BOUNDARY)

    def test_fenced_context_quote_is_ignored(self):
        for fence in ("```", "~~~"):
            with self.subTest(fence=fence):
                result, _ = self.run_reset(context="", deadline="0.1",
                                           startup=f">_ OpenAI Codex (v0.166.0)\n{fence}text\nContext 0% used\n{fence}\nStill starting")
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertEqual(result.stdout, self.NO_BOUNDARY)

    def test_fenced_reset_marker_does_not_freshen_stale_footer(self):
        result, _ = self.run_reset(old_context="Context 0% used", deadline="0.1",
                                   context="Context 0% used\n```\n/new\n```", ready_boundary="")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(result.stdout, self.NO_BOUNDARY)

    def test_nonzero_context_fails_even_after_startup(self):
        for delay in (0, 3):
            with self.subTest(delay=delay):
                result, _ = self.run_reset(delay=delay, context="Context 12% used")
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertEqual(result.stdout, "FAIL reset fixture-agent: Context 12% used after /new\n")

    def test_busy_status_refuses_reset(self):
        result, _ = self.run_reset(status="busy")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(result.stdout, "FAIL reset fixture-agent: status busy, not idle\n")

    def test_missing_chooser_fails(self):
        result, _ = self.run_reset(chooser=False)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(result.stdout, "FAIL reset fixture-agent: chooser never appeared\n")


class ResetFreshScreenTests(unittest.TestCase):
    """#434: welcome-like transcript must not re-prove a stale screen."""

    run_reset = ResetTests.run_reset
    SUCCESS = ResetTests.SUCCESS
    NO_BOUNDARY = ResetTests.NO_BOUNDARY
    SCREEN = Path(__file__).with_name("fixtures").joinpath("reset-fresh-codex.txt").read_text()

    def assert_stale(self, screen, expected=None):
        result, _ = self.run_reset(context=screen, ready_boundary="", startup="",
                                   deadline="0.1", locale="C",
                                   session_before="old-session", session_after="old-session")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(result.stdout, expected or self.NO_BOUNDARY)

    def test_embedded_title_does_not_erase_transcript(self):
        self.assert_stale(self.SCREEN.replace("› Ask Codex to do anything",
            "› hello\n• Hello!\n>_ OpenAI Codex (v0.166.0)\n› Ask Codex to do anything"))

    def test_old_placeholder_only_transcript_is_not_fresh(self):
        self.assert_stale(self.SCREEN.replace("› Ask Codex to do anything",
            "› Ask Codex to do anything\n› Ask Codex to do anything"))

    def test_old_welcome_tip_only_transcript_is_not_fresh(self):
        self.assert_stale(self.SCREEN.replace("› Ask Codex to do anything",
            "› Ask Codex to do anything\nTip: Use /help to see available commands."))

    def test_old_box_art_only_transcript_is_not_fresh(self):
        self.assert_stale(self.SCREEN.replace("› Ask Codex to do anything",
            "› Ask Codex to do anything\n╭──╮\n│  │\n╰──╯"))

    def test_saved_real_fresh_screen_passes(self):
        for screen in (self.SCREEN, self.SCREEN.replace("\n", "\r\n")):
            with self.subTest(crlf="\r" in screen):
                result, _ = self.run_reset(context=screen, ready_boundary="", locale="C",
                                           session_before="old-session", session_after="old-session")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(result.stdout, self.SUCCESS)

    def test_title_directly_after_leading_cwd_metadata_passes(self):
        screen = "\n~/fixture-worktree\n" + self.SCREEN.lstrip()
        result, _ = self.run_reset(context=screen, ready_boundary="", locale="C")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_old_scrollback_above_complete_fresh_header_passes(self):
        self.assert_fresh("old transcript\nContext 12% used\n" + self.SCREEN)

    def assert_fresh(self, screen, **kwargs):
        result, _ = self.run_reset(context=screen, ready_boundary="", locale="C",
                                   session_before="old-session", session_after="old-session", deadline="0.1", **kwargs)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, self.SUCCESS)

    def test_new_echo_above_fresh_header_passes(self):
        self.assert_fresh("› /new\n" + self.SCREEN)

    def test_chooser_above_fresh_header_passes(self):
        self.assert_fresh("Where should the new conversation run?\n1. Use current Git worktree\n" + self.SCREEN)

    def test_footer_hints_between_placeholder_and_footer_pass(self):
        for hint in ("? for shortcuts", "? for help", "? for commands"):
            with self.subTest(hint=hint):
                self.assert_fresh(self.SCREEN.replace("› Ask Codex to do anything",
                                                     "› Ask Codex to do anything\n" + hint))

    def test_twenty_five_row_pane_read_reaches_fresh_title(self):
        self.assertGreater(len(self.SCREEN.splitlines()), 25)
        self.assert_fresh(self.SCREEN, pane_height=25)

    def test_last_title_with_dirty_body_revokes_earlier_fresh_screen(self):
        self.assert_stale(self.SCREEN + "\n>_ OpenAI Codex (v0.166.0)\n~/fixture-worktree\n› old prompt\nContext 0% used")

    def test_cwd_metadata_rejects_slash_commands_and_spaces(self):
        for cwd in ("/new", "/help", "/tmp/old output", "~/old output"):
            with self.subTest(cwd=cwd):
                self.assert_stale(self.SCREEN.replace("~/fixture-worktree", cwd),
                    expected="FAIL reset fixture-agent: no context line after 0.1s\n" if cwd == "/new" else None)

    def test_cwd_metadata_accepts_absolute_path(self):
        self.assert_fresh(self.SCREEN.replace("~/fixture-worktree", "/tmp/fixture-worktree"))


class ResetShortScreenTests(unittest.TestCase):
    """#468: compact replays derived from the saved real Codex pane, not raw captures."""

    run_reset = ResetTests.run_reset
    SUCCESS = ResetTests.SUCCESS
    NO_BOUNDARY = ResetTests.NO_BOUNDARY
    NO_CONTEXT = "FAIL reset fixture-agent: no context line after 0.1s\n"
    RESIDUE = ("• Previous reply\n› /new\nWhere should the new conversation run?\n"
               "› 1. Use current Git worktree\n")
    # Derived input, not a raw capture: the saved real fixture's last 25 rows,
    # including every blank. Title and cwd are outside this contiguous short read.
    SHORT_DERIVED = Path(__file__).with_name("fixtures").joinpath("reset-fresh-codex-short-derived.txt").read_text()
    # Synthetic residue is a separate adversarial input, not captured pane history.
    TITLELESS = RESIDUE + SHORT_DERIVED
    LOGO = "\n".join(line for line in SHORT_DERIVED.splitlines()
                      if any("\u2800" <= c <= "\u28ff" for c in line))

    def replay(self, screen, **kwargs):
        return self.run_reset(context=screen, ready_boundary="", startup="", deadline="0.1",
                              locale="C", session_before="old-session", session_after="old-session", **kwargs)

    def assert_rejected(self, screen, expected=None):
        result, _ = self.replay(screen)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(result.stdout, expected or self.NO_BOUNDARY)

    def test_derived_contiguous_short_read_with_or_without_synthetic_residue_passes(self):
        self.assertEqual(len(self.SHORT_DERIVED.splitlines()), 25)
        self.assertEqual(self.SHORT_DERIVED, "\n".join(LIVE_RESET_SCREEN.splitlines()[-25:]) + "\n")
        for screen in (self.SHORT_DERIVED, self.TITLELESS):
            for identity in ("", "old-session"):
                with self.subTest(residue=screen == self.TITLELESS, identity=identity):
                    result, _ = self.run_reset(context=screen, ready_boundary="", startup="", deadline="0.1",
                                               locale="C", session_before=identity, session_after=identity)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertEqual(result.stdout, self.SUCCESS)

    def test_output_after_zero_footer_revokes_context_in_both_suffix_orders(self):
        for screen in (self.SHORT_DERIVED, self.TITLELESS, LIVE_RESET_SCREEN):
            for suffix in ("› hello", "• Previous reply", "› hello\n• Previous reply", "• Previous reply\n› hello"):
                with self.subTest(residue=screen == self.TITLELESS, suffix=suffix):
                    self.assert_rejected(screen + "\n" + suffix)

    def test_dirty_suffix_after_footer_hints_cannot_restore_zero_footer(self):
        for suffix in ("› hello", "• Previous reply", "╭──╮", "› Ask Codex to do anything", "```\nold reply\n```"):
            with self.subTest(suffix=suffix):
                self.assert_rejected(self.TITLELESS + "\n? for help\n\n" + suffix + "\nContext 0% used")

    def test_disallowed_suffix_before_allowed_hints_still_revokes_context(self):
        for suffix in ("› hello", "• Previous reply"):
            with self.subTest(suffix=suffix):
                self.assert_rejected(self.SHORT_DERIVED + "\n" + suffix + "\n? for help\n\n")

    def test_allowed_hints_and_blanks_after_final_footer_stay_fresh(self):
        result, _ = self.replay(self.SHORT_DERIVED + "\n? for help\n? for commands\n\n")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, self.SUCCESS)

    def test_older_header_separated_from_titleless_logo_is_scrollback(self):
        old = LIVE_RESET_SCREEN.replace("Context 0%", "Context 12%")
        for boundary in ("› /new\n", "Where should the new conversation run?\n1. Use current Git worktree\n", ""):
            with self.subTest(boundary=boundary):
                result, _ = self.replay(old + "\n" + boundary + self.SHORT_DERIVED)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(result.stdout, self.SUCCESS)

    def test_opus_trace_old_header_echo_chooser_new_logo_passes(self):
        old_header = LIVE_RESET_SCREEN.split("› Ask Codex to do anything")[0]
        result, _ = self.replay(old_header + self.RESIDUE + self.SHORT_DERIVED)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, self.SUCCESS)

    def test_later_title_or_dirty_earlier_header_still_vetoes_logo(self):
        self.assert_rejected(self.SHORT_DERIVED + "\n>_ OpenAI Codex (v0.166.0)\n› pending\nContext 0% used")
        for dirty in ("• Previous reply", "/help", "/tmp/old output"):
            with self.subTest(dirty=dirty):
                self.assert_rejected(">_ OpenAI Codex (v0.166.0)\n" + dirty + "\n› /new\n" + self.SHORT_DERIVED)

    def test_changed_identity_remains_independent_of_logo_placeholder(self):
        screen = self.TITLELESS.replace("› Ask Codex to do anything", "")
        result, _ = self.run_reset(context=screen, ready_boundary="", startup="", deadline="0.1",
                                   locale="C", session_before="old-session", session_after="new-session")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, self.SUCCESS)

    def test_changed_identity_accepts_logo_without_placeholder_or_residue(self):
        screen = self.TITLELESS.removeprefix(self.RESIDUE).replace("› Ask Codex to do anything", "")
        result, _ = self.run_reset(context=screen, ready_boundary="", startup="", deadline="0.1",
                                   locale="C", session_before="old-session", session_after="new-session")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, self.SUCCESS)

    def test_logo_candidate_does_not_hide_dirty_suffix(self):
        for screen in (self.TITLELESS,):
            for transcript in ("› hello\n• Hello!\n› Ask Codex to do anything",
                               "› Ask Codex to do anything\n• Previous reply",
                               "› Ask Codex to do anything\n› Ask Codex to do anything"):
                with self.subTest(title="OpenAI Codex" in screen, transcript=transcript):
                    self.assert_rejected(screen.replace("› Ask Codex to do anything", transcript))

    def test_logo_fallback_requires_full_logo_and_one_placeholder(self):
        for screen in (self.TITLELESS,):
            for logo in ("╭──╮\n│  │\n╰──╯", "\n".join(self.LOGO.splitlines()[:-1]), ""):
                with self.subTest(title="OpenAI Codex" in screen, logo=logo):
                    self.assert_rejected(screen.replace(self.LOGO, logo))
            with self.subTest(title="OpenAI Codex" in screen, placeholder=False):
                self.assert_rejected(screen.replace("› Ask Codex to do anything", ""), self.NO_CONTEXT)

    def test_quoted_or_fenced_logo_cannot_prove_freshness(self):
        for screen in (self.TITLELESS,):
            for quoted in ("\n".join("> " + line for line in screen.splitlines()),
                           "```\n" + screen + "\n```", "~~~\n" + screen + "\n~~~"):
                with self.subTest(title="OpenAI Codex" in screen, quoted=quoted[:20]):
                    self.assert_rejected(quoted)

    def test_logo_cannot_erase_dirty_metadata_below_latest_title(self):
        for content in ("• Previous reply", "/help", "/tmp/old output", "~/old output"):
            with self.subTest(content=content):
                screen = self.RESIDUE + ">_ OpenAI Codex (v0.166.0)\n" + content + "\n" + self.SHORT_DERIVED
                self.assert_rejected(screen)

    def test_later_marker_revokes_logo_context(self):
        for screen in (self.TITLELESS,):
            for marker in ("Where should the new conversation run?", "Starting MCP servers (3/4)", "› /new"):
                with self.subTest(title="OpenAI Codex" in screen, marker=marker):
                    self.assert_rejected(screen.replace("› Ask Codex to do anything",
                                                        "› Ask Codex to do anything\n" + marker), self.NO_CONTEXT)

    def test_logo_requires_bottommost_zero_footer(self):
        for screen in (self.TITLELESS,):
            footer = next(line for line in screen.splitlines() if "Context 0% used" in line)
            for suffix, expected in (("", self.NO_CONTEXT),
                                     (footer.replace("Context 0%", "Context 12%"),
                                      "FAIL reset fixture-agent: Context 12% used after /new\n"),
                                     (footer + "\nContext 12% used",
                                      "FAIL reset fixture-agent: Context 12% used after /new\n"),
                                     (footer + "\n› hello\n• Hello!\nContext 0% used", self.NO_BOUNDARY)):
                with self.subTest(title="OpenAI Codex" in screen, suffix=suffix):
                    self.assert_rejected(screen.replace(footer, suffix), expected)

    def test_logo_proof_and_footer_cannot_cross_reads_in_either_order(self):
        candidate = "\n".join(line for line in self.TITLELESS.splitlines() if "Context 0% used" not in line)
        for startup, context in ((candidate, "Context 0% used"), ("Context 0% used", candidate)):
            with self.subTest(logo_first=startup == candidate):
                result, _ = self.run_reset(delay=1, startup=startup, context=context,
                                           ready_boundary="", deadline="0.1", locale="C",
                                           session_before="old-session", session_after="old-session")
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertEqual(result.stdout, self.NO_CONTEXT)
                self.assertGreaterEqual(result.pane_gets, 3)


if __name__ == "__main__":
    unittest.main()
