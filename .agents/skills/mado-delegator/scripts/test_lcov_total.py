import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("lcov-total.py")


def run(text):
    with tempfile.NamedTemporaryFile("w", suffix=".info", delete=False) as f:
        f.write(text)
    return subprocess.run(["python3", str(SCRIPT), f.name], capture_output=True, text=True)


FULL = "SF:/a.swift\nDA:1,3\nDA:2,1\nLF:2\nLH:2\nFNF:1\nFNH:1\nend_of_record\n"


class LcovTotalTests(unittest.TestCase):
    def test_full_coverage_passes_and_prints_totals(self):
        result = run(FULL + FULL.replace("/a.swift", "/b.swift"))

        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("lines 4/4 functions 2/2", result.stdout)

    def test_one_uncovered_line_fails_and_names_it(self):
        # 2026-10-27: a rebased head reported lcov=0 while one line was uncovered.
        gap = "SF:/b.swift\nDA:7,1\nDA:27,0\nLF:2\nLH:1\nFNF:1\nFNH:1\nend_of_record\n"

        result = run(FULL + gap)

        self.assertEqual(result.returncode, 1)
        self.assertIn("lines 3/4", result.stdout)
        self.assertIn("/b.swift:27", result.stdout)

    def test_uncovered_function_fails(self):
        result = run(FULL.replace("FNH:1", "FNH:0"))

        self.assertEqual(result.returncode, 1)
        self.assertIn("functions 0/1", result.stdout)

    def test_empty_or_missing_report_fails(self):
        self.assertEqual(run("").returncode, 2)
        self.assertEqual(subprocess.run(["python3", str(SCRIPT), "/nonexistent.info"],
                                        capture_output=True).returncode, 2)


if __name__ == "__main__":
    unittest.main()
