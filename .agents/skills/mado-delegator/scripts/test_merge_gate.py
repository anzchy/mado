import json
import os
from pathlib import Path
import shutil
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
  'pr list') [ "${GH_LOOKUP_FAIL:-0}" = 1 ] && exit 9; case " $* " in *' --limit 200 '*) printf '%s\\n' "$GH_PRS" ;; *) echo '[]';; esac ;;
  'pr checks') printf '%s\\n' "$GH_CHECKS" ;;
  'pr merge') echo "$*" >> "$GH_MERGE_LOG" ;;
  'pr comment') echo "$*" >> "$GH_MERGE_LOG" ;;
  *) exit 9 ;;
esac
''')
        stub.chmod(0o755)
        node = self.bin / 'node'
        node.write_text('#!/bin/sh\nif [ "${NODE_REAL_EVIDENCE:-0}" = 1 ]; then case "$*" in *evidence.mjs*) exec "$REAL_NODE" "$@";; esac; fi\ncase "$*" in *evidence.mjs*) [ "$NODE_FAIL" = evidence ] && exit 1;; *local-pr-lint.mjs*) [ "$NODE_FAIL" = lint ] && exit 1;; esac\nexit 0\n')
        node.chmod(0o755)
        self.env = {**env, 'PATH': str(self.bin) + os.pathsep + os.environ['PATH'],
                    'REAL_NODE': shutil.which('node'),
                    'GH_HEAD': self.head, 'GH_MERGE_LOG': str(self.root / 'merged'),
                    'GH_MAIN': '[{"databaseId":1,"headSha":"abc","status":"completed","conclusion":"success"}]',
                    'GH_PRS': '[]', 'GH_CHECKS': '[{"name":"CI","state":"SUCCESS"}]'}

    def run_gate(self, *args, **extra):
        return subprocess.run(['sh', str(SCRIPT), '12', *args], cwd=self.repo, env={**self.env, **extra},
                              capture_output=True, text=True)

    def test_green_ready_pr_reports_would_allow_without_merging(self):
        result = self.run_gate()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('would-allow', result.stdout)
        self.assertFalse((self.root / 'merged').exists())

    def test_linked_record_is_accepted_and_forged_head_is_refused(self):
        record = self.repo / '.build/mado-verify' / f'{self.head}.json'
        linked = json.loads(record.read_text())
        linked.update({'base': self.head, 'link': {'oldBase': self.head, 'newBase': self.head,
                                                 'oldHead': self.head, 'newHead': self.head}})
        record.write_text(json.dumps(linked))
        self.assertIn('would-allow', self.run_gate().stdout)
        linked['link']['newHead'] = '0' * 40
        record.write_text(json.dumps(linked))
        self.assertIn('would-refuse condition-failed: invalid linked mado-verify head/base', self.run_gate().stdout)

    def test_linked_record_runs_real_evidence_verifier_and_refuses_forged_provenance(self):
        env = self.env
        verify_source = SCRIPT.parents[2] / 'mado-verify' / 'scripts'
        verify_target = self.repo / '.agents/skills/mado-verify/scripts'
        verify_target.mkdir(parents=True)
        for name in ('gate-policy.mjs', 'evidence.mjs', 'reuse-policy.mjs', 'reuse-check.mjs', 'reuse-allowlist.json'):
            shutil.copy2(verify_source / name, verify_target / name)
        rebase_target = self.repo / '.agents/skills/mado-delegator/scripts'
        rebase_target.mkdir(parents=True)
        for name in ('rebase-verify.sh', 'rebase-verify-tree.py', 'scan-conflict-markers.py'):
            shutil.copy2(SCRIPT.with_name(name), rebase_target / name)
        subprocess.run(['git', 'add', '.agents'], cwd=self.repo, check=True, env=env)
        subprocess.run(['git', 'commit', '-qm', 'policy baseline'], cwd=self.repo, check=True, env=env)
        old_base = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=self.repo, text=True).strip()
        subprocess.run(['git', 'update-ref', 'refs/remotes/origin/main', old_base], cwd=self.repo, check=True)
        subprocess.run(['git', 'switch', '-qc', 'topic'], cwd=self.repo, check=True, env=env)
        (self.repo / 'feature').write_text('topic\n')
        subprocess.run(['git', 'add', 'feature'], cwd=self.repo, check=True, env=env)
        subprocess.run(['git', 'commit', '-qm', 'topic'], cwd=self.repo, check=True, env=env)
        old_head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=self.repo, text=True).strip()
        names = ['diffcheck', 'swift', 'lcov', 'xcodegen', 'xcodebuild', 'apptests', 'node', 'ledger', 'design']
        gates = [{'name': name, 'command': name, 'exitCode': 0} for name in names]
        source = self.repo / 'evidence-input.json'
        source.write_text(json.dumps({'issue': 766, 'task': 'fixture', 'branch': 'topic', 'head': old_head,
                                      'gates': gates, 'integrity': 'none', 'byType': [], 'notVerified': [],
                                      'commentUrl': 'https://github.com/anzchy/mado/issues/766#issuecomment-1'}))
        for name in ('xcodebuild', 'swift'):
            tool = self.bin / name
            tool.write_text('#!/bin/sh\necho fixed-toolchain\n')
            tool.chmod(0o755)
        real_node = shutil.which('node')
        self.assertEqual(subprocess.run([real_node, str(verify_target / 'evidence.mjs'), 'record', str(source)],
                         cwd=self.repo, env=env, capture_output=True, text=True).returncode, 0)
        subprocess.run(['git', 'switch', '-q', 'main'], cwd=self.repo, check=True, env=env)
        (self.repo / 'docs').mkdir()
        (self.repo / 'docs/note.md').write_text('main\n')
        subprocess.run(['git', 'add', 'docs/note.md'], cwd=self.repo, check=True, env=env)
        subprocess.run(['git', 'commit', '-qm', 'main advance'], cwd=self.repo, check=True, env=env)
        new_base = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=self.repo, text=True).strip()
        subprocess.run(['git', 'update-ref', 'refs/remotes/origin/main', new_base], cwd=self.repo, check=True)
        subprocess.run(['git', 'switch', '-q', 'topic'], cwd=self.repo, check=True, env=env)
        subprocess.run(['git', 'rebase', 'main'], cwd=self.repo, check=True, env=env)
        new_head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=self.repo, text=True).strip()
        linked = [{'name': name, 'command': name, 'exitCode': 0,
                   **({'reusedFrom': old_head} if name in ('swift', 'lcov') else {})} for name in names]
        source.write_text(json.dumps({'issue': 766, 'task': 'linked', 'branch': 'topic', 'head': new_head, 'base': new_base,
                                      'link': {'oldBase': old_base, 'newBase': new_base, 'oldHead': old_head,
                                               'newHead': new_head}, 'gates': linked, 'integrity': 'none',
                                      'byType': [], 'notVerified': [],
                                      'commentUrl': 'https://github.com/anzchy/mado/issues/766#issuecomment-2'}))
        recorded = subprocess.run([real_node, str(verify_target / 'evidence.mjs'), 'record', str(source)],
                                  cwd=self.repo, env=env, capture_output=True, text=True)
        self.assertEqual(recorded.returncode, 0, recorded.stderr)
        options = {'GH_HEAD': new_head, 'NODE_REAL_EVIDENCE': '1'}
        self.assertIn('would-allow', self.run_gate(**options).stdout)
        record = self.repo / '.build/mado-verify' / f'{new_head}.json'
        forged = json.loads(record.read_text())
        forged['fingerprints']['allowlistVersion'] = 'forged'
        record.write_text(json.dumps(forged))
        self.assertIn('would-refuse condition-failed: mado-verify evidence failed', self.run_gate(**options).stdout)

    def test_red_main_blocks_merge(self):
        main = '[{"databaseId":42,"headSha":"abc","status":"completed","conclusion":"failure"}]'
        result = self.run_gate(GH_MAIN=main)
        self.assertEqual(result.returncode, 0)
        self.assertIn('would-refuse condition-failed: main CI', result.stdout + result.stderr)
        self.assertFalse((self.root / 'merged').exists())

    def test_older_ready_pr_blocks_merge(self):
        prs = '[{"number":11,"createdAt":"2026-01-01T00:00:00Z","isDraft":false}]'
        result = self.run_gate(GH_PRS=prs)
        self.assertEqual(result.returncode, 0)
        self.assertIn('would-refuse condition-failed: older ready PR', result.stdout + result.stderr)

    def test_older_ready_pr_at_position_31_blocks_merge(self):
        rows = [{'number': n, 'createdAt': '2026-02-01T00:00:00Z', 'isDraft': False}
                for n in range(20, 50)]
        rows.append({'number': 11, 'createdAt': '2026-01-01T00:00:00Z', 'isDraft': False})
        result = self.run_gate(GH_PRS=json.dumps(rows))
        self.assertIn('would-refuse condition-failed: older ready PR #11', result.stdout)

    def test_rebased_head_uses_audited_record_with_code_same(self):
        old_base = self.head
        env = self.env
        subprocess.run(['git', 'switch', '-qc', 'topic'], cwd=self.repo, check=True, env=env)
        (self.repo / 'file').write_text('changed')
        subprocess.run(['git', 'commit', '-qam', 'topic change'], cwd=self.repo, check=True, env=env)
        old = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=self.repo, text=True).strip()
        record = self.repo / '.build/mado-verify' / f'{old}.json'
        record.write_text(json.dumps({'issue': 766, 'head': old, 'commentUrl':
                                      'https://github.com/anzchy/mado/issues/766#issuecomment-1'}))
        subprocess.run(['git', 'switch', '-q', 'main'], cwd=self.repo, check=True, env=env)
        (self.repo / 'main-only').write_text('main advance\n')
        subprocess.run(['git', 'add', 'main-only'], cwd=self.repo, check=True, env=env)
        subprocess.run(['git', 'commit', '-qm', 'main advance'], cwd=self.repo, check=True, env=env)
        new_base = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=self.repo, text=True).strip()
        subprocess.run(['git', 'update-ref', 'refs/remotes/origin/main', new_base], cwd=self.repo, check=True)
        subprocess.run(['git', 'switch', '-q', 'topic'], cwd=self.repo, check=True, env=env)
        subprocess.run(['git', 'rebase', 'main'], cwd=self.repo, check=True, env=env)
        new = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=self.repo, text=True).strip()
        verifier = self.repo / '.agents/skills/mado-delegator/scripts'
        verifier.mkdir(parents=True)
        for name in ('rebase-verify.sh', 'rebase-verify-tree.py', 'scan-conflict-markers.py'):
            shutil.copy2(SCRIPT.with_name(name), verifier / name)
        proof = subprocess.run(['zsh', str(verifier / 'rebase-verify.sh'), old_base, old, new_base, new],
                               cwd=self.repo, capture_output=True, text=True)
        self.assertEqual(proof.returncode, 0, proof.stdout + proof.stderr)
        self.assertIn('CODE same ', proof.stdout)
        result = self.run_gate('--audited', old, GH_HEAD=new)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('would-allow', result.stdout)
        self.assertFalse((self.root / 'merged').exists())
        missing = self.run_gate(GH_HEAD=new)
        self.assertIn('would-refuse condition-failed: --audited <sha> required', missing.stdout)

    def test_wrong_audited_option_prints_usage(self):
        result = self.run_gate('--wrong', self.head)
        self.assertEqual(result.returncode, 2)
        self.assertIn('usage: merge-gate.sh', result.stderr)

    def test_rebased_head_with_real_code_difference_is_refused(self):
        old_base = self.head
        env = self.env
        subprocess.run(['git', 'switch', '-qc', 'topic'], cwd=self.repo, check=True, env=env)
        (self.repo / 'file').write_text('changed')
        subprocess.run(['git', 'commit', '-qam', 'topic change'], cwd=self.repo, check=True, env=env)
        old = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=self.repo, text=True).strip()
        record = self.repo / '.build/mado-verify' / f'{old}.json'
        record.write_text(json.dumps({'issue': 766, 'head': old, 'commentUrl':
                                      'https://github.com/anzchy/mado/issues/766#issuecomment-1'}))
        subprocess.run(['git', 'switch', '-q', 'main'], cwd=self.repo, check=True, env=env)
        (self.repo / 'main-only').write_text('main advance\n')
        subprocess.run(['git', 'add', 'main-only'], cwd=self.repo, check=True, env=env)
        subprocess.run(['git', 'commit', '-qm', 'main advance'], cwd=self.repo, check=True, env=env)
        new_base = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=self.repo, text=True).strip()
        subprocess.run(['git', 'update-ref', 'refs/remotes/origin/main', new_base], cwd=self.repo, check=True)
        subprocess.run(['git', 'switch', '-q', 'topic'], cwd=self.repo, check=True, env=env)
        subprocess.run(['git', 'rebase', 'main'], cwd=self.repo, check=True, env=env)
        (self.repo / 'file').write_text('changed-differently')
        subprocess.run(['git', 'commit', '-qa', '--amend', '--no-edit'], cwd=self.repo, check=True, env=env)
        new = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=self.repo, text=True).strip()
        verifier = self.repo / '.agents/skills/mado-delegator/scripts'
        verifier.mkdir(parents=True)
        for name in ('rebase-verify.sh', 'rebase-verify-tree.py', 'scan-conflict-markers.py'):
            shutil.copy2(SCRIPT.with_name(name), verifier / name)
        proof = subprocess.run(['zsh', str(verifier / 'rebase-verify.sh'), old_base, old, new_base, new],
                               cwd=self.repo, capture_output=True, text=True)
        self.assertEqual(proof.returncode, 1, proof.stdout + proof.stderr)
        self.assertIn('CODE differ ', proof.stdout)
        result = self.run_gate('--audited', old, GH_HEAD=new)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('would-refuse condition-failed: rebase-verify CODE same required', result.stdout)
        self.assertFalse((self.root / 'merged').exists())

    def test_failing_check_evidence_or_lint_blocks_merge(self):
        for extra in ({'GH_CHECKS': '[{"name":"CI","state":"FAILURE"}]'},
                      {'NODE_FAIL': 'evidence'}, {'NODE_FAIL': 'lint'}):
            with self.subTest(extra=extra):
                result = self.run_gate(**extra)
                self.assertEqual(result.returncode, 0)
                self.assertIn('would-refuse condition-failed:', result.stdout + result.stderr)
                self.assertFalse((self.root / 'merged').exists())

    def test_lookup_failure_is_distinct_and_suggests_retry_or_override(self):
        result = self.run_gate(GH_LOOKUP_FAIL='1')
        self.assertEqual(result.returncode, 0)
        self.assertIn('would-refuse lookup-failed:', result.stdout)
        self.assertIn('retry or use the override', result.stdout)

    def test_override_logs_and_comments_with_reason(self):
        result = self.run_gate(MADO_MERGE_GATE_OVERRIDE='owner reviewed CI failure',
                               GH_MAIN='[{"databaseId":42,"headSha":"abc","status":"completed","conclusion":"failure"}]',
                               HOME=str(self.root))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('override recorded', result.stdout)
        log = self.root / '.mado/handoff/merge-gate-overrides.log'
        self.assertIn('owner reviewed CI failure', log.read_text())
        self.assertIn('pr comment 12', (self.root / 'merged').read_text())

    def test_blank_override_reason_is_rejected_without_comment(self):
        result = self.run_gate(MADO_MERGE_GATE_OVERRIDE='  ', HOME=str(self.root))
        self.assertEqual(result.returncode, 2)
        self.assertIn('reason must be nonempty', result.stderr)
        self.assertFalse((self.root / 'merged').exists())


if __name__ == '__main__':
    unittest.main()
