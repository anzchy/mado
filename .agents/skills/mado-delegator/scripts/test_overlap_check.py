import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("overlap-check.py")
ENV = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.invalid",
       "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.invalid"}


def git(cwd, *args):
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True, env=ENV).stdout


class OverlapCheckTests(unittest.TestCase):
    """overlap-check.py: trial-merge in-flight branches onto origin/main, and check a new brief's files."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.origin, self.repo = root / "origin", root / "work"
        self.origin.mkdir()
        git(self.origin, "init", "-q", "-b", "main")
        (self.origin / "App").mkdir()
        (self.origin / "docs").mkdir()
        self.files(self.origin, **{
            "App/Coordinator.swift": "".join(f"line {i}\n" for i in range(1, 21)),
            "App/Grid.swift": "grid\n", "App/Viewer.swift": "viewer\n", "App/Other.swift": "other\n",
            "docs/feature-ledger.md": "rows\n", "docs/feature-ledger.html": "<p>rows</p>\n"})
        git(self.origin, "commit", "-qm", "init")
        git(root, "clone", "-q", str(self.origin), str(self.repo))
        self.base = git(self.repo, "rev-parse", "HEAD").strip()

    def tearDown(self):
        self.tmp.cleanup()

    def files(self, repo, **contents):
        for path, text in contents.items():
            (repo / path).write_text(text)
        git(repo, "add", *contents)

    def branch(self, name, **contents):
        git(self.repo, "switch", "-qc", name, self.base)
        self.files(self.repo, **contents)
        git(self.repo, "commit", "-qm", f"work on {name}")
        git(self.repo, "switch", "-q", "--detach", self.base)

    def main_moves(self, **contents):
        self.files(self.origin, **contents)
        git(self.origin, "commit", "-qm", "main moves")
        git(self.repo, "fetch", "-q", "origin")

    def run_check(self, *args):
        result = subprocess.run(["python3", str(SCRIPT), "--json", *args], cwd=self.repo, capture_output=True,
                                text=True, env=ENV)
        return result.returncode, (json.loads(result.stdout) if result.stdout.strip() else None), result

    def coordinator(self, changed_line, text):
        lines = [f"line {i}\n" for i in range(1, 21)]
        lines[changed_line - 1] = text + "\n"
        return "".join(lines)

    def test_branch_untouched_by_main_is_clean(self):
        self.branch("p/clean", **{"App/Grid.swift": "grid 2\n"})
        self.main_moves(**{"App/Viewer.swift": "viewer 2\n"})

        rc, report, result = self.run_check("trial", "p/clean")

        self.assertEqual(rc, 0, result.stderr)
        self.assertEqual(report[0]["status"], "CLEAN")
        self.assertEqual(report[0]["overlap"], [])

    def test_textual_code_conflict_is_reported_with_its_files(self):
        self.branch("p/conflict", **{"App/Grid.swift": "grid branch\n"})
        self.main_moves(**{"App/Grid.swift": "grid main\n"})

        rc, report, _ = self.run_check("trial", "p/conflict")

        self.assertEqual(rc, 2)
        self.assertEqual(report[0]["status"], "CODE")
        self.assertEqual(report[0]["conflicts"], ["App/Grid.swift"])

    def test_conflict_only_in_generated_ledger_html_is_ignorable(self):
        self.branch("p/ledger", **{"docs/feature-ledger.html": "<p>branch</p>\n", "App/Grid.swift": "grid 2\n"})
        self.main_moves(**{"docs/feature-ledger.html": "<p>main</p>\n"})

        rc, report, _ = self.run_check("trial", "p/ledger")

        self.assertEqual(rc, 0)
        self.assertEqual(report[0]["status"], "LEDGER")
        self.assertEqual(report[0]["conflicts"], ["docs/feature-ledger.html"])

    def test_same_file_changed_in_different_hunks_is_an_overlap_without_a_conflict(self):
        # The #134 x #108 shape: git merges it cleanly, but the two changes meet in one module.
        self.branch("p/overlap", **{"App/Coordinator.swift": self.coordinator(2, "branch change")})
        self.main_moves(**{"App/Coordinator.swift": self.coordinator(18, "main change")})

        rc, report, _ = self.run_check("trial", "p/overlap")

        self.assertEqual(rc, 1)
        self.assertEqual(report[0]["status"], "OVERLAP")
        self.assertEqual(report[0]["conflicts"], [])
        self.assertEqual(report[0]["overlap"], ["App/Coordinator.swift"])

    def test_ledger_files_alone_are_not_an_overlap(self):
        self.branch("p/rows", **{"docs/feature-ledger.md": "rows branch\nrows\n", "App/Grid.swift": "grid 2\n"})
        self.main_moves(**{"docs/feature-ledger.md": "rows\nrows main\n"})

        rc, report, _ = self.run_check("trial", "p/rows")

        self.assertEqual(rc, 0)
        self.assertEqual(report[0]["overlap"], [])

    def test_branch_with_no_commits_of_its_own_is_empty_not_merged(self):
        git(self.repo, "branch", "p/started", self.base)
        self.main_moves(**{"App/Viewer.swift": "viewer 2\n"})

        rc, report, _ = self.run_check("trial", "p/started")

        self.assertEqual(rc, 0)
        self.assertEqual(report[0]["status"], "EMPTY")

    def test_rebase_merged_branch_is_merged(self):
        # gh pr merge --rebase puts new SHAs on main; the branch's patches are there, its commits are not.
        self.branch("p/done", **{"App/Grid.swift": "grid 2\n"})
        sha = git(self.repo, "rev-parse", "p/done").strip()
        git(self.origin, "fetch", "-q", str(self.repo), "p/done")
        self.main_moves(**{"App/Viewer.swift": "viewer 2\n"})
        git(self.origin, "cherry-pick", sha)
        git(self.repo, "fetch", "-q", "origin")

        rc, report, _ = self.run_check("trial", "p/done")

        self.assertEqual(rc, 0)
        self.assertEqual(report[0]["status"], "MERGED")

    def test_uncommitted_work_in_a_branch_worktree_is_flagged(self):
        # A trial merge only sees commits; uncommitted edits must be reported, not reported as clean.
        git(self.repo, "branch", "p/wip", self.base)
        wt = Path(self.tmp.name) / "wip"
        git(self.repo, "worktree", "add", "-q", str(wt), "p/wip")
        (wt / "App/Grid.swift").write_text("grid edited\n")

        rc, report, _ = self.run_check("trial")

        wip = next(r for r in report if r["branch"] == "p/wip")
        self.assertEqual(wip["status"], "EMPTY")
        self.assertTrue(wip["uncommitted"])

    def test_claim_names_in_flight_branches_that_already_change_the_planned_files(self):
        self.branch("p/watch", **{"App/Coordinator.swift": self.coordinator(5, "watch")})
        self.branch("p/grid", **{"App/Grid.swift": "grid 2\n"})

        rc, report, _ = self.run_check("claim", "--branches", "p/watch", "p/grid", "--",
                                       "App/Coordinator.swift", "App/Viewer.swift")

        self.assertEqual(rc, 1)
        self.assertEqual(report, [{"branch": "p/watch", "shared": ["App/Coordinator.swift"]}])

    def test_claim_with_no_shared_files_is_clear(self):
        self.branch("p/grid", **{"App/Grid.swift": "grid 2\n"})

        rc, report, _ = self.run_check("claim", "--branches", "p/grid", "--", "App/Other.swift")

        self.assertEqual(rc, 0)
        self.assertEqual(report, [])

    def test_unknown_branch_is_a_usage_error(self):
        rc, _, result = self.run_check("trial", "p/nope")

        self.assertEqual(rc, 3)
        self.assertIn("p/nope", result.stderr)


if __name__ == "__main__":
    unittest.main()
