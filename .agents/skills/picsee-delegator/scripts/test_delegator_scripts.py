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

    def test_head_mismatch_writes_no_gate_results(self):
        rc, summary = self.run_gates(str(Path(__file__).resolve().parent), "0" * 40)

        self.assertEqual(rc, 2)
        self.assertEqual(summary.strip(), "head mismatch")

    def test_missing_worktree_is_refused(self):
        rc, summary = self.run_gates("/nonexistent-picsee-worktree", "HEAD")

        self.assertEqual(rc, 2)
        self.assertIn("no worktree", summary)


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
                for name in ("owner-gates.sh", "lcov-total.py"):
                    (tools / name).write_text((source / name).read_text())

                def executable(path, text):
                    path.write_text("#!/bin/sh\n" + text)
                    path.chmod(0o755)

                for folder in ("agents", "tdd", "ledger"):
                    directory = work / "scripts" / folder
                    directory.mkdir(exist_ok=True)
                    (directory / "fixture.test.mjs").write_text("// command fixture\n")
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
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                summary = (out / "t-summary.txt").read_text().splitlines()
                self.assertIn(f"design={design_rc}", summary)
                self.assertEqual(summary[-1], "DONE")
                self.assertLess(summary.index(f"design={design_rc}"), summary.index("DONE"))
                self.assertEqual((out / "t-design.log").read_text().strip(), f"design fixture rc={design_rc}")


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


class ResetTests(unittest.TestCase):
    """Run the real reset CLI through chooser/startup/context transitions."""

    SUCCESS = ("reset fixture-agent old_session=old-session Context 0% used "
               "(verify the session id changes after the next turn)\n")

    def run_reset(self, *, delay=0, context="Context 0% used", status="idle", chooser=True, deadline="2"):
        import time

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            herdr = root / "herdr"
            herdr.write_text('''#!/bin/sh
case "$1 $2" in
  'agent get')
    printf '{"agent_status":"%s","value":"old-session"}\\n' "$RESET_STATUS"
    ;;
  'pane send-text')
    echo 0 > "$RESET_STATE/enters"
    echo 0 > "$RESET_STATE/reads"
    ;;
  'pane send-keys')
    n=$(cat "$RESET_STATE/enters")
    echo $((n + 1)) > "$RESET_STATE/enters"
    ;;
  'pane read')
    n=$(cat "$RESET_STATE/enters")
    if [ "$RESET_CHOOSER" = 0 ]; then
      echo 'ordinary pane, no chooser'
    elif [ "$n" -lt 2 ]; then
      echo 'Where should the new conversation run?'
    else
      n=$(cat "$RESET_STATE/reads")
      echo $((n + 1)) > "$RESET_STATE/reads"
      if [ "$n" -lt "$RESET_DELAY" ] || [ -z "$RESET_CONTEXT" ]; then
        echo 'Starting MCP servers (3/4)'
      else
        printf '%s\\n' "$RESET_CONTEXT"
      fi
    fi
    ;;
  *) exit 90 ;;
esac
''')
            herdr.chmod(0o755)
            # Bypass the existing chooser's fixed sleeps as well as the configured zero poll interval.
            sleep = root / "sleep"
            sleep.write_text("#!/bin/sh\nexit 0\n")
            sleep.chmod(0o755)
            env = {**os.environ, "PATH": str(root) + os.pathsep + os.environ["PATH"],
                   "RESET_STATE": str(root), "RESET_STATUS": status, "RESET_CHOOSER": str(int(chooser)),
                   "RESET_DELAY": str(delay), "RESET_CONTEXT": context,
                   "PICSEE_RESET_CONTEXT_SECS": deadline, "PICSEE_RESET_POLL_SECS": "0"}
            started = time.monotonic()
            result = subprocess.run(["zsh", str(Path(__file__).with_name("reset.sh")),
                                     "fixture-agent", "fixture-pane"],
                                    capture_output=True, text=True, env=env, timeout=5)
            return result, time.monotonic() - started

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

    def test_zero_deadline_observes_immediate_context(self):
        result, _ = self.run_reset(deadline="0")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, self.SUCCESS)

    def test_zero_deadline_without_context_fails(self):
        result, _ = self.run_reset(context="", deadline="0")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(result.stdout, "FAIL reset fixture-agent: no context line after 0s\n")

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


if __name__ == "__main__":
    unittest.main()
