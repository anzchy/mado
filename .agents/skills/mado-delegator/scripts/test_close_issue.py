import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).with_name('close-issue.sh')


class CloseIssueTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.log = root / 'close.log'
        stub = root / 'gh'
        stub.write_text('''#!/bin/sh
case "$1 $2" in
  'run list') case " $* " in *' --event push '*) ;; *) exit 9;; esac; printf '%s\\n' "$GH_RUNS" ;;
  'issue close') echo "$*" >> "$GH_CLOSE_LOG" ;;
  *) exit 9 ;;
esac
''')
        stub.chmod(0o755)
        self.env = {**os.environ, 'PATH': str(root) + os.pathsep + os.environ['PATH'],
                    'GH_CLOSE_LOG': str(self.log)}
        self.green = '{"databaseId":1,"headSha":"abc","status":"completed","conclusion":"success"}'
        self.red = '{"databaseId":2,"headSha":"def","status":"completed","conclusion":"failure"}'

    def call(self, runs):
        return subprocess.run(['sh', str(SCRIPT), '749'], env={**self.env, 'GH_RUNS': runs},
                              capture_output=True, text=True)

    def test_two_green_runs_close_issue(self):
        second = self.green.replace('"databaseId":1', '"databaseId":3')
        result = self.call(f'[{self.green},{second}]')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('issue close 749', self.log.read_text())

    def test_one_green_or_latest_red_refuses(self):
        for runs in (f'[{self.green}]', f'[{self.green},{self.green}]',
                     f'[{self.red},{self.green}]'):
            with self.subTest(runs=runs):
                result = self.call(runs)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.log.exists())


if __name__ == '__main__':
    unittest.main()
