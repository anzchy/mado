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


LIVE_RESET_SCREEN = '\n  >_ OpenAI Codex (v0.166.0)\n     ~/Documents/mac-app/picsee-wt/device-v001\n\n\n\n\n                                           ⣀⣤⣤⣤⣀⣀\n                                        ⣠⣶⣿⣿⣿⣿⣿⣿⣿⣿⣦⣤⣤⣤⣤⣤⣤⡀\n                                      ⢀⣾⣿⣿⠿⠋⠉⠉⢉⣭⣿⣿⣿⣿⣿⠿⣿⣿⣿⣿⣷⣄\n                                     ⣀⣾⣿⣿⠃ ⣀⣴⣾⣿⣿⡿⠟⠋ ⣀⡀ ⠈⠙⢿⣿⣿⣧\n                                  ⣀⣶⣿⣿⣿⣿⡇ ⢸⣿⣿⡿⠛⠉⢀⣠⣴⣿⣿⣿⣷⣦⣀⠈⢻⣿⣿⡇\n                                 ⣰⣿⣿⡿⢿⣿⣿⡇ ⢸⣿⣿⢀⣤⣶⣿⣿⣿⠟⠛⠻⣿⣿⣿⣿⣮⣿⣿⡷\n                                ⢰⣿⣿⡟⠁⢸⣿⣿⡇ ⢸⣿⣿⣿⣿⠿⠿⣿⣿⣿⣦⣄⡀⠈⠛⠿⣿⣿⣿⣧⡀\n                                ⣾⣿⣿⠃ ⢸⣿⣿⡇ ⢸⣿⣿⠋⠁  ⠈⠙⢻⣿⣿⣿⣶⣤⡀ ⠹⢿⣿⣷⡄\n                                ⢸⣿⣿⣇ ⠸⣿⣿⣷⣦⣼⣿⣿      ⢸⣿⣿⠻⢿⣿⣿⡇ ⠘⣿⣿⣿\n                                ⠈⢿⣿⣿⣦⡀⠈⠛⠿⣿⣿⣿⣿⣄⡀  ⢀⣠⣼⣿⣿  ⣿⣿⡇  ⣿⣿⣿⠇\n                                  ⢻⣿⣿⣿⣷⣦⣀⠈⠙⠻⣿⣿⣿⣶⣶⣿⣿⣿⣿⣿  ⣿⣿⡇ ⣠⣿⣿⣿\n                                  ⢸⣿⣿⡿⢿⣿⣿⣿⣦⣠⣴⣿⣿⣿⡿⠟⠋⢸⣿⣿  ⣿⣿⣷⣴⣿⣿⣿⠃\n                                  ⠘⣿⣿⣷ ⠈⠛⢿⣿⣿⣿⠿⠋⠉ ⣠⣴⣿⣿⣿  ⣿⣿⣿⣿⣿⠟⠁\n                                   ⠻⣿⣿⣿⣤⣀ ⠈⠉ ⢀⣤⣶⣿⣿⣿⠿⠟⠁ ⣰⣿⣿⡟⠋⠁\n                                    ⠈⠿⣿⣿⣿⣿⣶⣾⣿⣿⣿⣿⠟⠋⠁  ⣠⣼⣿⣿⡟\n                                       ⠙⠛⠛⠛⠻⠛⢿⣿⣿⣿⣿⣷⣾⣿⣿⣿⡿⠏\n                                              ⠈⠙⠛⠿⠿⠿⠿⠛⠉\n\n\n\n\n› Ask Codex to do anything\n\n  GPT-6-Sol medium · Context 0% used · ~/Documents/mac-app/picsee-wt/device-v001\n  ? for shortcuts\n'


class ResetTests(unittest.TestCase):
    """Run the real reset CLI through chooser/startup/context transitions."""

    SUCCESS = ("reset fixture-agent old_session=old-session Context 0% used "
               "(verify the session id changes after the next turn)\n")

    def run_reset(self, *, delay=0, context="Context 0% used", status="idle", chooser=True, deadline="2",
                  poll="0.01", prefix="", startup="Starting MCP servers (3/4)", timer_var=None, old_context="",
                  ready_boundary="/new", locale=None, session_before="", session_after="", session_delay=0):
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
                   "RESET_DELAY": str(delay), "RESET_CONTEXT": context,
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

    def test_changed_session_id_proves_markerless_footer(self):
        result, _ = self.run_reset(session_before="old-session", session_after="new-session", ready_boundary="")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, self.SUCCESS)

    def test_unchanged_session_id_never_accepts_header_or_command(self):
        for screen in (LIVE_RESET_SCREEN, "/new\nContext 0% used"):
            with self.subTest(screen=screen):
                result, _ = self.run_reset(session_before="old-session", session_after="old-session",
                                           context=screen, ready_boundary="", deadline="0.1")
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertEqual(result.stdout,
                                 "FAIL reset fixture-agent: session id unchanged after 0.1s; check the pane\n")

    def test_session_id_change_is_polled_before_success(self):
        result, _ = self.run_reset(session_before="old-session", session_after="new-session", session_delay=2)
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
                self.assertEqual(result.stdout, "FAIL reset fixture-agent: no context line after 0.1s\n")

    def test_changed_id_does_not_accept_footer_under_chooser(self):
        result, _ = self.run_reset(session_before="old-session", session_after="new-session",
                                   prefix="Where should the new conversation run?", ready_boundary="", deadline="0.1")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(result.stdout, "FAIL reset fixture-agent: no context line after 0.1s\n")

    def test_unchanged_session_id_waits_on_nonzero_footer(self):
        result, elapsed = self.run_reset(session_before="old-session", session_after="old-session",
                                         context="Context 12% used", deadline="0.1")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(result.stdout,
                         "FAIL reset fixture-agent: session id unchanged after 0.1s; check the pane\n")
        self.assertGreaterEqual(elapsed, 0.09)

    def test_quoted_or_fenced_decorated_footer_is_ignored(self):
        footer = LIVE_RESET_SCREEN.splitlines()[-2]
        for quoted in ('> ' + footer.strip(), '"' + footer.strip() + '"',
                       'The pane says ' + footer.strip(), '```\n' + footer + '\n```',
                       '~~~\n' + footer + '\n~~~'):
            with self.subTest(quoted=quoted):
                result, _ = self.run_reset(context=quoted, deadline="0.1")
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

    def test_stale_zero_before_new_session_cannot_succeed_early(self):
        for marker in ("Where should the new conversation run?", "/new", "Starting MCP servers (3/4)"):
            with self.subTest(marker=marker):
                result, _ = self.run_reset(delay=3, context="Context 12% used",
                                           prefix=f"Context 0% used\n{marker}")
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertEqual(result.stdout, "FAIL reset fixture-agent: Context 12% used after /new\n")

    def test_old_nonzero_above_new_zero_succeeds(self):
        result, _ = self.run_reset(prefix="Context 12% used\n/new")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, self.SUCCESS)

    def test_bottommost_new_footer_decides(self):
        result, _ = self.run_reset(context="Context 0% used\nContext 12% used")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(result.stdout, "FAIL reset fixture-agent: Context 12% used after /new\n")

    def test_quoted_context_in_body_is_ignored(self):
        for quote in ('The issue says "Context 0% used" during startup.', '"Context 0% used"',
                      '> Context 0% used'):
            with self.subTest(quote=quote):
                result, _ = self.run_reset(context="", deadline="0.1", startup=f"/new\n{quote}")
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertEqual(result.stdout, "FAIL reset fixture-agent: no context line after 0.1s\n")

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
        self.assertEqual(result.stdout, "FAIL reset fixture-agent: no context line after 0.1s\n")

    def test_footer_under_last_chooser_is_not_session_context(self):
        for context in ("Context 0% used", "Context 37% used"):
            with self.subTest(context=context):
                result, _ = self.run_reset(prefix="/new\nWhere should the new conversation run?",
                                           context=context, ready_boundary="", deadline="0.1")
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertEqual(result.stdout, "FAIL reset fixture-agent: no context line after 0.1s\n")

    def test_chooser_footer_waits_for_started_session(self):
        result, _ = self.run_reset(delay=1, startup="Where should the new conversation run?\nContext 37% used")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, self.SUCCESS)

    def test_boundary_prefixes_work_in_c_locale(self):
        for boundary in ("/new", "> /new", "❯ /new", "› /new", "Starting MCP servers (3/4)"):
            for context in ("Context 0% used", "Context 12% used"):
                with self.subTest(boundary=boundary, context=context):
                    result, _ = self.run_reset(ready_boundary=boundary, locale="C", context=context)
                    self.assertEqual(result.returncode, 0 if context == "Context 0% used" else 1,
                                     result.stdout + result.stderr)
                    self.assertEqual(result.stdout, self.SUCCESS if context == "Context 0% used" else
                                     "FAIL reset fixture-agent: Context 12% used after /new\n")

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
                                           startup=f"/new\n{fence}text\nContext 0% used\n{fence}\nStill starting")
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertEqual(result.stdout, "FAIL reset fixture-agent: no context line after 0.1s\n")

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


if __name__ == "__main__":
    unittest.main()
