# -*- coding: utf-8 -*-
"""#733: rebase-verify keeps audit verdicts when only allowlisted doc table rows differ; the states README rows
merge per row key. Black-box: every case runs the scripts in a throwaway Git repository."""
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).parent
README = "design/prototypes/picsee-browser/states/README.md"
HEADER = "| 页面 | 不带参数 | 子情况 |"
LEDGER_HEADER = "| ID | 能力 | 状态 | 验证 | 计划 | 在哪 | 怎么确认 |"
ENV = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.invalid",
       "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.invalid"}


def git(cwd, *args, check=True):
    return subprocess.run(["git", *args], cwd=cwd, check=check, capture_output=True, text=True, env=ENV).stdout


def readme(rows, intro="intro", tail="tail"):
    return "\n".join(["# States", "", intro, "", HEADER, "| --- | --- | --- |", *rows, "", tail, ""])


def row(key, plain, cases):
    return f"| `{key}` | {plain} | {cases} |"


ROW_A = row("a.html", "A plain", "A cases")
ROW_B = row("b.html", "B plain", "B cases")
ROW_C = row("c.html", "C plain", "C cases")
ROW_A_BRANCH = row("a.html", "A plain", "A cases; branch")
ROW_B_MAIN = row("b.html", "B plain; main", "B cases")


def ledger(accept="打开一张图片，看到它。", limit="限制：无。"):
    return "\n".join(["# Ledger", "", LEDGER_HEADER, "| --- | --- | --- | --- | --- | --- | --- |",
                      f"| VIEW-01 | 看图 | Partial | auto | P1-01 | App | {accept}{limit} |", ""])


class Repo:
    def __init__(self, root):
        self.root = root
        git(root, "init", "-q", "-b", "main")

    def commit(self, message, **files):
        for path, text in files.items():
            target = self.root / path
            if text is None:
                git(self.root, "rm", "-q", path)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(text)
            git(self.root, "add", path)
        git(self.root, "commit", "-qm", message)
        return self.head()

    def head(self):
        return git(self.root, "rev-parse", "HEAD").strip()

    def switch(self, ref):
        git(self.root, "switch", "--detach", "-q", ref)


class RebaseVerifyDocsTests(unittest.TestCase):
    """The three results: CODE same, CODE same + DOCS differ, CODE differ; each prints the differing paths."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Repo(Path(self.tmp.name))
        self.old_base = self.repo.commit("init", **{
            "App/a.swift": "a\n", "App/c.swift": "c1\nc2\nc3\nc4\nc5\nc6\nc7\nc8\n", "notes.md": "n\n",
            README: readme([ROW_A, ROW_B, ROW_C]), "docs/feature-ledger.md": ledger()})
        # The audited branch: code plus a states README row (row a's 子情况).
        self.old_head = self.repo.commit("feat: topic\n\n#7 P1-01 VIEW-01", **{
            "App/a.swift": "a2\n", README: readme([ROW_A_BRANCH, ROW_B, ROW_C])})
        self.repo.switch(self.old_base)
        # Upstream edits the adjacent row b (git's 3-way replay conflicts on adjacent lines, as on #687b).
        self.new_base = self.repo.commit("docs: main moved", **{
            "notes.md": "n2\n", README: readme([ROW_A, ROW_B_MAIN, ROW_C])})

    def tearDown(self):
        self.tmp.cleanup()

    def rebased(self, readme_rows=None, **extra):
        self.repo.switch(self.new_base)
        rows = [ROW_A_BRANCH, ROW_B_MAIN, ROW_C] if readme_rows is None else readme_rows
        return self.repo.commit("feat: topic\n\n#7 P1-01 VIEW-01", **{"App/a.swift": "a2\n", README: readme(rows),
                                                                        **extra})

    def verify(self, new_base=None, new_head=None):
        return subprocess.run(["zsh", str(HERE / "rebase-verify.sh"), self.old_base, self.old_head,
                               new_base or self.new_base, new_head or self.repo.head()],
                              cwd=self.repo.root, capture_output=True, text=True)

    def assertDiffer(self, result, *paths):
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("CODE differ", result.stdout)
        self.assertNotIn("DOCS differ", result.stdout)
        for path in paths:
            self.assertIn(f"DIFF {path}", result.stdout)

    def test_only_allowlisted_rows_differ_keeps_the_verdict(self):
        self.rebased()
        result = self.verify()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("MESSAGES same", result.stdout)
        self.assertIn("CODE same, DOCS differ", result.stdout)
        self.assertIn(f"DIFF {README}", result.stdout)
        self.assertNotIn("CODE differ", result.stdout)

    def test_ledger_limit_text_may_change_with_docs_differ(self):
        self.rebased(**{"docs/feature-ledger.md": ledger(limit="限制：只有自动测试。")})
        result = self.verify()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("CODE same, DOCS differ", result.stdout)

    def test_exact_replay_stays_code_same_without_diff_lines(self):
        # Upstream touched a far-away file only: the replay is clean and exact.
        self.repo.switch(self.old_base)
        far_base = self.repo.commit("docs: far", **{"notes.md": "n3\n"})
        self.repo.switch(far_base)
        head = self.repo.commit("feat: topic\n\n#7 P1-01 VIEW-01", **{
            "App/a.swift": "a2\n", README: readme([ROW_A_BRANCH, ROW_B, ROW_C])})
        result = self.verify(new_base=far_base, new_head=head)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("CODE same ", result.stdout)
        self.assertNotIn("DOCS differ", result.stdout)
        self.assertNotIn("DIFF ", result.stdout)

    def test_code_difference_prints_its_path(self):
        self.repo.switch(self.new_base)
        self.repo.commit("feat: topic\n\n#7 P1-01 VIEW-01", **{
            "App/a.swift": "a3\n", README: readme([ROW_A_BRANCH, ROW_B_MAIN, ROW_C])})
        self.assertDiffer(self.verify(), "App/a.swift")

    def test_path_outside_the_allowlist_differs(self):
        self.rebased(**{"notes.md": "n2 edited\n"})
        self.assertDiffer(self.verify(), "notes.md")

    def test_non_row_line_in_an_allowlisted_file_differs(self):
        self.repo.switch(self.new_base)
        self.repo.commit("feat: topic\n\n#7 P1-01 VIEW-01", **{
            "App/a.swift": "a2\n", README: readme([ROW_A_BRANCH, ROW_B_MAIN, ROW_C], intro="intro edited")})
        self.assertDiffer(self.verify(), README)

    def test_lost_upstream_row_edit_differs(self):
        self.rebased([ROW_A_BRANCH, ROW_B, ROW_C])
        self.assertDiffer(self.verify(), README)

    def test_lost_branch_row_edit_differs(self):
        self.rebased([ROW_A, ROW_B_MAIN, ROW_C])
        self.assertDiffer(self.verify(), README)

    def test_deleted_row_differs(self):
        self.rebased([ROW_A_BRANCH, ROW_B_MAIN])
        self.assertDiffer(self.verify(), README)

    def test_duplicate_row_key_differs(self):
        self.rebased([ROW_A_BRANCH, ROW_B_MAIN, ROW_C, ROW_A_BRANCH])
        self.assertDiffer(self.verify(), README)

    def test_acceptance_text_change_differs(self):
        self.rebased(**{"docs/feature-ledger.md": ledger(accept="打开图片即可。")})
        result = self.verify()
        self.assertDiffer(result, README)
        self.assertIn("acceptance", result.stdout)

    def test_same_cell_edited_on_both_sides_differs(self):
        self.repo.switch(self.old_base)
        both_base = self.repo.commit("docs: main edits row a", **{
            README: readme([row("a.html", "A plain", "A cases; main"), ROW_B, ROW_C])})
        self.repo.switch(both_base)
        head = self.repo.commit("feat: topic\n\n#7 P1-01 VIEW-01", **{
            "App/a.swift": "a2\n", README: readme([row("a.html", "A plain", "A cases; main; branch"), ROW_B, ROW_C])})
        self.assertDiffer(self.verify(new_base=both_base, new_head=head), README)

    def test_upstream_code_overlap_goes_to_the_combination_check(self):
        # Upstream also changed a code file the branch changed; the rows alone would qualify.
        self.repo.switch(self.old_base)
        branch = self.repo.commit("feat: topic\n\n#7 P1-01 VIEW-01", **{
            "App/a.swift": "a2\n", "App/c.swift": "c1\nc2\nc3\nc4\nc5\nc6\nc7\nbranch\n",
            README: readme([ROW_A_BRANCH, ROW_B, ROW_C])})
        self.old_head = branch
        self.repo.switch(self.old_base)
        upstream = self.repo.commit("feat: main code", **{
            "App/c.swift": "main\nc2\nc3\nc4\nc5\nc6\nc7\nc8\n", README: readme([ROW_A, ROW_B_MAIN, ROW_C])})
        self.repo.switch(upstream)
        head = self.repo.commit("feat: topic\n\n#7 P1-01 VIEW-01", **{
            "App/a.swift": "a2\n", "App/c.swift": "main\nc2\nc3\nc4\nc5\nc6\nc7\nbranch\n",
            README: readme([ROW_A_BRANCH, ROW_B_MAIN, ROW_C])})
        result = self.verify(new_base=upstream, new_head=head)
        self.assertDiffer(result, README)
        self.assertIn("UPSTREAM OVERLAP App/c.swift", result.stdout)

    def test_messages_differ_still_wins_over_docs_differ(self):
        self.repo.switch(self.new_base)
        self.repo.commit("feat: topic", **{"App/a.swift": "a2\n", README: readme([ROW_A_BRANCH, ROW_B_MAIN, ROW_C])})
        result = self.verify()
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("MESSAGES differ", result.stdout)
        self.assertIn("CODE same, DOCS differ", result.stdout)


class ResolveDocRowsTests(unittest.TestCase):
    """resolve_doc_rows.py merges the conflicted states README per row key from index stages 1/2/3."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Repo(Path(self.tmp.name))
        self.base = self.repo.commit("init", **{README: readme([ROW_A, ROW_B, ROW_C]), "x.md": "x\n"})

    def tearDown(self):
        self.tmp.cleanup()

    def conflict(self, ours_rows, theirs_rows, ours_kw=None, theirs_kw=None):
        self.repo.switch(self.base)
        theirs = self.repo.commit("theirs", **{README: readme(theirs_rows, **(theirs_kw or {}))})
        self.repo.switch(self.base)
        self.repo.commit("ours", **{README: readme(ours_rows, **(ours_kw or {}))})
        git(self.repo.root, "merge", "-q", "--no-edit", theirs, check=False)
        self.assertIn("UU", git(self.repo.root, "status", "--porcelain"), "fixture must conflict")

    def resolve(self, path=README):
        self.assertTrue((HERE / "resolve_doc_rows.py").is_file(), "resolve_doc_rows.py is missing")
        return subprocess.run(["python3", str(HERE / "resolve_doc_rows.py"), path], cwd=self.repo.root,
                              capture_output=True, text=True)

    def content(self):
        return (self.repo.root / README).read_text()

    def test_adjacent_row_edits_merge_by_key(self):
        self.conflict([ROW_A, ROW_B_MAIN, ROW_C], [ROW_A_BRANCH, ROW_B, ROW_C])
        result = self.resolve()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.content(), readme([ROW_A_BRANCH, ROW_B_MAIN, ROW_C]))

    def test_different_cells_of_one_row_merge(self):
        self.conflict([row("a.html", "A plain; main", "A cases"), ROW_B, ROW_C], [ROW_A_BRANCH, ROW_B_MAIN, ROW_C])
        result = self.resolve()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.content(), readme([row("a.html", "A plain; main", "A cases; branch"), ROW_B_MAIN, ROW_C]))

    def test_rows_added_on_both_sides_are_kept_in_a_fixed_order(self):
        new_main, new_branch = row("d.html", "D", "D"), row("e.html", "E", "E")
        # Both insert after row b: main's order first, then the branch's row before its next row (c).
        self.conflict([ROW_A, ROW_B, new_main, ROW_C], [ROW_A, ROW_B, new_branch, ROW_C])
        result = self.resolve()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.content(), readme([ROW_A, ROW_B, new_main, new_branch, ROW_C]))

    def test_frame_edit_on_one_side_is_kept(self):
        self.conflict([ROW_A, ROW_B_MAIN, ROW_C], [ROW_A_BRANCH, ROW_B, ROW_C], theirs_kw={"tail": "tail edited"})
        result = self.resolve()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.content(), readme([ROW_A_BRANCH, ROW_B_MAIN, ROW_C], tail="tail edited"))

    def assertManual(self, result, word):
        self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
        self.assertIn(word, result.stdout)
        self.assertIn("<<<<<<<", self.content(), "the conflict stays for a human")

    def test_same_cell_both_sides_stops(self):
        self.conflict([row("a.html", "A plain", "A cases; main"), ROW_B, ROW_C], [ROW_A_BRANCH, ROW_B, ROW_C])
        self.assertManual(self.resolve(), "same cell")

    def test_deletion_stops(self):
        self.conflict([ROW_A, ROW_B_MAIN], [ROW_A_BRANCH, ROW_B, ROW_C])
        self.assertManual(self.resolve(), "deleted")

    def test_duplicate_key_stops(self):
        self.conflict([ROW_A, ROW_B_MAIN, ROW_C, row("b.html", "again", "again")], [ROW_A_BRANCH, ROW_B, ROW_C])
        self.assertManual(self.resolve(), "duplicate")

    def test_same_new_key_with_different_content_stops(self):
        self.conflict([ROW_A, ROW_B_MAIN, ROW_C, row("d.html", "D main", "D")],
                      [ROW_A_BRANCH, ROW_B, ROW_C, row("d.html", "D branch", "D")])
        self.assertManual(self.resolve(), "added on both sides")

    def test_frame_edits_on_both_sides_stop(self):
        self.conflict([ROW_A, ROW_B_MAIN, ROW_C], [ROW_A_BRANCH, ROW_B, ROW_C],
                      ours_kw={"tail": "tail main"}, theirs_kw={"tail": "tail branch"})
        self.assertManual(self.resolve(), "outside the table")

    def test_path_outside_the_allowlist_is_refused(self):
        result = self.resolve("x.md")
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("not in the allowlist", result.stdout)


STUB_BUILD = """import fs from 'node:fs';
const html = '<p>' + fs.readFileSync('docs/feature-ledger.md', 'utf8').trim() + '</p>\\n';
if (process.argv.includes('--check')) process.exit(fs.readFileSync('docs/feature-ledger.html', 'utf8') === html ? 0 : 1);
fs.writeFileSync('docs/feature-ledger.html', html);
"""


class RebaseLedgerDocRowsTests(unittest.TestCase):
    """rebase-ledger.sh resolves a states README row conflict with the row merger and stops on a manual one."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        (root / "origin").mkdir()
        self.origin = Repo(root / "origin")
        self.origin.commit("init", **{"scripts/ledger/build.mjs": STUB_BUILD, "docs/feature-ledger.md": "base\n",
                                      "docs/feature-ledger.html": "<p>base</p>\n", README: readme([ROW_A, ROW_B, ROW_C])})
        self.work = root / "work"
        git(root, "clone", "-q", str(self.origin.root), str(self.work))
        git(self.work, "switch", "-qc", "topic")
        bin_dir = root / "bin"
        bin_dir.mkdir()
        (bin_dir / "gh").write_text("#!/bin/sh\nprintf '%s\\n' '[{\"databaseId\":42,\"headSha\":\"abc\","
                                    "\"status\":\"completed\",\"conclusion\":\"success\"}]'\n")
        (bin_dir / "gh").chmod(0o755)
        self.env = {**ENV, "PATH": str(bin_dir) + os.pathsep + os.environ["PATH"]}

    def tearDown(self):
        self.tmp.cleanup()

    def run_rebase(self, topic_rows, main_rows):
        (self.work / README).write_text(readme(topic_rows))
        git(self.work, "commit", "-qam", "topic\n\n#7 P1-01 VIEW-01")
        self.origin.commit("main", **{README: readme(main_rows)})
        return subprocess.run(["zsh", str(HERE / "rebase-ledger.sh"), "origin/main"], cwd=self.work,
                              capture_output=True, text=True, env=self.env)

    def test_row_conflict_is_resolved_and_the_rebase_finishes(self):
        result = self.run_rebase([ROW_A_BRANCH, ROW_B, ROW_C], [ROW_A, ROW_B_MAIN, ROW_C])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("DONE resolved", result.stdout)
        self.assertEqual((self.work / README).read_text(), readme([ROW_A_BRANCH, ROW_B_MAIN, ROW_C]))
        self.assertIn("#7 P1-01 VIEW-01", git(self.work, "log", "-1", "--format=%B"))

    def test_manual_row_stops_with_the_rebase_in_progress(self):
        result = self.run_rebase([ROW_A_BRANCH, ROW_B, ROW_C], [row("a.html", "A plain", "A cases; main"), ROW_B, ROW_C])
        self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
        self.assertIn(f"STOP manual doc row {README}", result.stdout)
        self.assertTrue((self.work / ".git/rebase-merge").is_dir(), "the rebase stays in progress")


class AllowlistAndStepSixTests(unittest.TestCase):
    """The allowlist is a repo file quoting the owner; step 6 of the skill and the guide states the new rule."""

    def test_allowlist_names_the_states_table_and_quotes_the_owner(self):
        allowlist = HERE / "rebase-docs-allowlist.txt"
        self.assertTrue(allowlist.is_file(), "allowlist file missing")
        text = allowlist.read_text()
        self.assertIn("「3+5 文档冲突不再作废审计」", text)
        self.assertIn("#733", text)
        entries = [line.split("\t") for line in text.splitlines() if line and not line.startswith("#")]
        self.assertEqual(entries, [[README, HEADER]])

    def test_step_six_describes_the_three_results(self):
        for doc in (HERE.parent / "SKILL.md", HERE.parent / "references/guide.md"):
            with self.subTest(doc=doc.name):
                text = doc.read_text()
                self.assertIn("CODE same, DOCS differ", text)
                self.assertIn("rebase-docs-allowlist.txt", text)
                self.assertIn("resolve_doc_rows.py", text)
                self.assertIn("UPSTREAM OVERLAP", text)
                self.assertIn("High", text)


ALLOWLIST = ".agents/skills/mado-delegator/scripts/rebase-docs-allowlist.txt"
ROW_ORDER_BRANCH = [ROW_C, ROW_A_BRANCH, ROW_B]


class RebaseVerifyModeOrderAllowlistTests(unittest.TestCase):
    """i733-fix1: the docs verdict checks tree modes/types, keeps a branch-only row reorder, and reads the allowlist
    from the new base, not from the checkout running the script."""

    setUp = RebaseVerifyDocsTests.setUp
    tearDown = RebaseVerifyDocsTests.tearDown
    verify = RebaseVerifyDocsTests.verify
    assertDiffer = RebaseVerifyDocsTests.assertDiffer

    def commit_on(self, base, message, files, executable=(), symlinks=None):
        """Commit on `base`; `executable` paths get mode 100755, `symlinks` {path: text} become 120000 entries."""
        root = self.repo.root
        self.repo.switch(base)
        for path, text in files.items():
            (root / path).parent.mkdir(parents=True, exist_ok=True)
            (root / path).write_text(text)
            os.chmod(root / path, 0o755 if path in executable else 0o644)
            git(root, "add", path)
        for path, text in (symlinks or {}).items():
            sha = subprocess.run(["git", "hash-object", "-w", "--stdin"], cwd=root, input=text, capture_output=True,
                                 text=True, check=True, env=ENV).stdout.strip()
            git(root, "update-index", "--add", "--cacheinfo", f"120000,{sha},{path}")
        git(root, "commit", "-qm", message)
        git(root, "reset", "-q", "--hard")
        return self.repo.head()

    def head_on_new_base(self, rows, executable=(), symlink=False, base=None):
        text = readme(rows)
        files = {"App/a.swift": "a2\n"} if symlink else {"App/a.swift": "a2\n", README: text}
        return self.commit_on(base or self.new_base, "feat: topic\n\n#7 P1-01 VIEW-01", files, executable,
                              {README: text} if symlink else None)

    def executable_branch(self):
        self.old_head = self.commit_on(self.old_base, "feat: topic\n\n#7 P1-01 VIEW-01", {
            "App/a.swift": "a2\n", README: readme([ROW_A_BRANCH, ROW_B, ROW_C])}, executable=(README,))

    def test_mode_kept_in_the_rebase_keeps_the_verdict(self):
        self.executable_branch()
        head = self.head_on_new_base([ROW_A_BRANCH, ROW_B_MAIN, ROW_C], executable=(README,))
        result = self.verify(new_head=head)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("CODE same, DOCS differ", result.stdout)

    def test_mode_lost_in_the_rebase_differs(self):
        self.executable_branch()
        result = self.verify(new_head=self.head_on_new_base([ROW_A_BRANCH, ROW_B_MAIN, ROW_C]))
        self.assertDiffer(result, README)
        self.assertIn("100755", result.stdout)
        self.assertIn("100644", result.stdout)

    def test_mode_gained_in_the_rebase_differs(self):
        result = self.verify(new_head=self.head_on_new_base([ROW_A_BRANCH, ROW_B_MAIN, ROW_C], executable=(README,)))
        self.assertDiffer(result, README)
        self.assertIn("mode", result.stdout)

    def test_file_turned_into_a_symlink_with_the_merged_text_differs(self):
        result = self.verify(new_head=self.head_on_new_base([ROW_A_BRANCH, ROW_B_MAIN, ROW_C], symlink=True))
        self.assertDiffer(result, README)
        self.assertIn("120000", result.stdout)

    def test_branch_only_row_reorder_is_kept(self):
        self.old_head = self.commit_on(self.old_base, "feat: topic\n\n#7 P1-01 VIEW-01", {
            "App/a.swift": "a2\n", README: readme(ROW_ORDER_BRANCH)})
        result = self.verify(new_head=self.head_on_new_base([ROW_C, ROW_A_BRANCH, ROW_B_MAIN]))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("CODE same, DOCS differ", result.stdout)

    def test_lost_branch_row_reorder_differs(self):
        self.old_head = self.commit_on(self.old_base, "feat: topic\n\n#7 P1-01 VIEW-01", {
            "App/a.swift": "a2\n", README: readme(ROW_ORDER_BRANCH)})
        self.assertDiffer(self.verify(new_head=self.head_on_new_base([ROW_A_BRANCH, ROW_B_MAIN, ROW_C])), README)

    def test_allowlist_comes_from_the_new_base(self):
        # Main's allowlist lists nothing: the script's own copy must not govern this verification.
        base = self.commit_on(self.old_base, "docs: main moved", {
            "notes.md": "n2\n", README: readme([ROW_A, ROW_B_MAIN, ROW_C]),
            ALLOWLIST: "# empty allowlist on main\n"})
        result = self.verify(new_base=base, new_head=self.head_on_new_base([ROW_A_BRANCH, ROW_B_MAIN, ROW_C], base=base))
        self.assertDiffer(result, README)

    def test_allowlist_on_the_new_base_is_honoured(self):
        base = self.commit_on(self.old_base, "docs: main moved", {
            "notes.md": "n2\n", README: readme([ROW_A, ROW_B_MAIN, ROW_C]), ALLOWLIST: f"# main\n{README}\t{HEADER}\n"})
        result = self.verify(new_base=base, new_head=self.head_on_new_base([ROW_A_BRANCH, ROW_B_MAIN, ROW_C], base=base))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("CODE same, DOCS differ", result.stdout)


class ResolveDocRowsOrderTests(unittest.TestCase):
    """i733-fix1: a reorder of existing rows survives when only one side reordered; both reordering differently stops."""

    setUp = ResolveDocRowsTests.setUp
    tearDown = ResolveDocRowsTests.tearDown
    conflict = ResolveDocRowsTests.conflict
    resolve = ResolveDocRowsTests.resolve
    content = ResolveDocRowsTests.content
    assertManual = ResolveDocRowsTests.assertManual

    def test_branch_only_reorder_with_an_adjacent_upstream_edit_is_kept(self):
        self.conflict([ROW_A, ROW_B_MAIN, ROW_C], ROW_ORDER_BRANCH)
        result = self.resolve()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.content(), readme([ROW_C, ROW_A_BRANCH, ROW_B_MAIN]))

    def test_main_only_reorder_with_a_branch_edit_is_kept(self):
        self.conflict([ROW_C, ROW_A, ROW_B], [ROW_A_BRANCH, ROW_B_MAIN, ROW_C])
        result = self.resolve()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.content(), readme([ROW_C, ROW_A_BRANCH, ROW_B_MAIN]))

    def test_both_sides_reordering_differently_stops(self):
        self.conflict([ROW_B, ROW_A, ROW_C], ROW_ORDER_BRANCH)
        self.assertManual(self.resolve(), "order")

if __name__ == "__main__":
    # The rebase-docs-py receipt lane runs this file directly; the summary line is the count the receipt parses.
    import sys
    outcome = unittest.main(exit=False).result
    print(f"Tests run: {outcome.testsRun}, Failures: {len(outcome.failures)}, Errors: {len(outcome.errors)}, "
          f"Skipped: {len(outcome.skipped)}")
    sys.exit(0 if outcome.wasSuccessful() else 1)
