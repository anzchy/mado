import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).with_name('merge-gate.sh')


class MergeGateTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.repo = self.root / 'repo'
        self.repo.mkdir()
        subprocess.run(['git', 'init', '-q', '-b', 'main'], cwd=self.repo, check=True)
        (self.repo / 'file').write_text('x')
        env = {**os.environ, 'GIT_AUTHOR_NAME': 't', 'GIT_AUTHOR_EMAIL': 't@example.invalid',
               'GIT_COMMITTER_NAME': 't', 'GIT_COMMITTER_EMAIL': 't@example.invalid'}
        subprocess.run(['git', 'add', 'file'], cwd=self.repo, check=True, env=env)
        subprocess.run(['git', 'commit', '-qm', 'init'], cwd=self.repo, check=True, env=env)
        self.head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=self.repo, text=True).strip()
        record = self.repo / '.build/mado-verify' / f'{self.head}.json'
        record.parent.mkdir(parents=True)
        record.write_text(json.dumps({'issue': 766, 'head': self.head, 'commentUrl':
                                      'https://github.com/anzchy/mado/issues/766#issuecomment-1'}))
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        stub = self.bin / 'gh'
        stub.write_text('''#!/bin/sh
case "$1 $2" in
  'run list') printf '%s\\n' "$GH_MAIN" ;;
  'pr view') printf '{"headRefOid":"%s","isDraft":false,"body":"body","createdAt":"2026-01-02T00:00:00Z"}\\n' "$GH_HEAD" ;;
  'pr list') printf '%s\\n' "$GH_PRS" ;;
  'pr checks') printf '%s\\n' "$GH_CHECKS" ;;
  'pr merge') echo "$*" >> "$GH_MERGE_LOG" ;;
  *) exit 9 ;;
esac
''')
        stub.chmod(0o755)
        node = self.bin / 'node'
        node.write_text('#!/bin/sh\ncase "$*" in *evidence.mjs*) [ "$NODE_FAIL" = evidence ] && exit 1;; *local-pr-lint.mjs*) [ "$NODE_FAIL" = lint ] && exit 1;; esac\nexit 0\n')
        node.chmod(0o755)
        self.env = {**env, 'PATH': str(self.bin) + os.pathsep + os.environ['PATH'],
                    'GH_HEAD': self.head, 'GH_MERGE_LOG': str(self.root / 'merged'),
                    'GH_MAIN': '[{"databaseId":1,"headSha":"abc","status":"completed","conclusion":"success"}]',
                    'GH_PRS': '[]', 'GH_CHECKS': '[{"name":"CI","state":"SUCCESS"}]'}

    def run_gate(self, **extra):
        return subprocess.run(['sh', str(SCRIPT), '12'], cwd=self.repo, env={**self.env, **extra},
                              capture_output=True, text=True)

    def test_green_ready_pr_merges(self):
        result = self.run_gate()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('pr merge --rebase 12', (self.root / 'merged').read_text())

    def test_red_main_blocks_merge(self):
        main = '[{"databaseId":42,"headSha":"abc","status":"completed","conclusion":"failure"}]'
        result = self.run_gate(GH_MAIN=main)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('main CI', result.stdout + result.stderr)
        self.assertFalse((self.root / 'merged').exists())

    def test_older_ready_pr_blocks_merge(self):
        prs = '[{"number":11,"createdAt":"2026-01-01T00:00:00Z","isDraft":false}]'
        result = self.run_gate(GH_PRS=prs)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('older ready PR', result.stdout + result.stderr)

    def test_failing_check_evidence_or_lint_blocks_merge(self):
        for extra in ({'GH_CHECKS': '[{"name":"CI","state":"FAILURE"}]'},
                      {'NODE_FAIL': 'evidence'}, {'NODE_FAIL': 'lint'}):
            with self.subTest(extra=extra):
                result = self.run_gate(**extra)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.root / 'merged').exists())


if __name__ == '__main__':
    unittest.main()
