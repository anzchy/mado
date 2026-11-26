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
  'pr view') if [ -n "${GH_VIEW:-}" ]; then printf '%s\\n' "$GH_VIEW"; else printf '{"headRefOid":"%s","isDraft":false,"body":"body","createdAt":"2026-01-02T00:00:00Z"}\\n' "$GH_HEAD"; fi ;;
  'pr list') [ "${GH_LOOKUP_FAIL:-0}" = 1 ] && exit 9; case " $* " in *' --limit 200 '*) printf '%s\\n' "$GH_PRS" ;; *) echo '[]';; esac ;;
  'pr checks') printf '%s\\n' "$GH_CHECKS" ;;
  'pr merge') echo "$*" >> "$GH_MERGE_LOG" ;;
  'pr comment') echo "$*" >> "$GH_MERGE_LOG" ;;
  *) exit 9 ;;
esac
''')
        stub.chmod(0o755)
        node = self.bin / 'node'
        node.write_text('#!/bin/sh\nif [ "${NODE_REAL_EVIDENCE:-0}" = 1 ]; then case "$*" in *evidence.mjs*) exec "$REAL_NODE" "$@";; esac; fi\nif [ "${NODE_REAL_LINT:-0}" = 1 ]; then case "$*" in *local-pr-lint.mjs*) exec "$REAL_NODE" "$@";; esac; fi\ncase "$*" in *evidence.mjs*) [ "$NODE_FAIL" = evidence ] && exit 1;; *local-pr-lint.mjs*) [ "$NODE_FAIL" = lint ] && exit 1;; esac\nexit 0\n')
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
        for name in ('gate-policy.mjs', 'evidence.mjs', 'tdd-separation.mjs', 'task-worktree.mjs', 'reuse-policy.mjs', 'reuse-check.mjs', 'reuse-allowlist.json'):
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



# #789: merge-gate accepts the #733 verdict "CODE same, DOCS differ" exactly when rebase-verify does (allowlisted rows
# only, per-row merge keeps both sides, acceptance text unchanged, no upstream overlap) and no known High is waived.
import sys
sys.path.insert(0, str(Path(__file__).parent))
from test_rebase_docs import (ALLOWLIST, README, ROW_A, ROW_A_BRANCH, ROW_B, ROW_B_MAIN, ROW_C, Repo, ledger,
                              readme)

import re

REPO_ROOT = SCRIPT.parents[4]
GOOD_AUDIT = '| audit | PASS | {sha} | two rounds, no Critical/High open; the Mediums are listed in Still open |'
GOOD_STILL_OPEN = '- Medium: a tooling note (not fixed here).'
LANES = ['package-tests', 'package-coverage', 'app-tests', 'unsigned-build', 'node-tooling', 'ledger', 'diff-check',
         'design-check', 'audit', 'device-smoke']
PLAIN = re.compile(r'^CODE same ([0-9a-f]{40}) \(exact replayed tree match; candidate patch ([0-9a-f]{40})\)$')
DOCS = re.compile(r'^CODE same, DOCS differ ([0-9a-f]{40}) \(only allowlisted doc rows differ; per-row merge keeps '
                  r'both sides; candidate patch ([0-9a-f]{40})\)$')


def body(audit=GOOD_AUDIT, still_open=GOOD_STILL_OPEN, heading='### Still open', extra=''):
    return '\n'.join(['## Summary', '', 'x', '', '## Gates', '', '| Lane | Status | SHA | Source |',
                      '| --- | --- | --- | --- |', audit, '', heading, still_open, '', extra])


def lint_body(audit_source, sha):
    """A body the real trusted PR-body lint passes: every lane, UI-Parity table and Device-Smoke line."""
    rows = [f'| audit | PASS | {sha} | {audit_source} |' if lane == 'audit' else f'| {lane} | N/A | — | fixture lane |'
            for lane in LANES]
    return '\n'.join(['## Summary', '', 'x', '', '## UI-Parity', '', '| Page | Status |', '| --- | --- |',
                      '| viewer | AUTO-PASS |', '', 'Device-Smoke: n/a — fixture, no device path', '', '## Gates', '',
                      '| Lane | Status | SHA | Source |', '| --- | --- | --- | --- |', *rows, '', '### Still open',
                      GOOD_STILL_OPEN, ''])


class MergeGateDocsDifferTests(unittest.TestCase):
    MESSAGE = 'feat: topic\n\n#7 P1-01 VIEW-01'

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / 'repo').mkdir()
        self.repo = Repo(self.root / 'repo')
        scripts = {f'.agents/skills/mado-delegator/scripts/{name}': SCRIPT.with_name(name).read_text()
                   for name in ('rebase-verify.sh', 'rebase-verify-tree.py', 'scan-conflict-markers.py', 'doc_rows.py')}
        lint = {f'scripts/agents/{name}': (REPO_ROOT / 'scripts/agents' / name).read_text()
                for name in ('local-pr-lint.mjs', 'ui-parity-pr-body-lint.mjs')}
        self.old_base = self.repo.commit('init', **scripts, **lint, **{
            'App/a.swift': 'a\n', 'App/c.swift': 'c1\nc2\nc3\nc4\nc5\nc6\nc7\nc8\n', 'notes.md': 'n\n',
            README: readme([ROW_A, ROW_B, ROW_C]), 'docs/feature-ledger.md': ledger(),
            ALLOWLIST: SCRIPT.with_name('rebase-docs-allowlist.txt').read_text()})
        self.old_head = self.repo.commit(self.MESSAGE, **{'App/a.swift': 'a2\n', README: readme([ROW_A_BRANCH, ROW_B, ROW_C])})
        self.repo.switch(self.old_base)
        self.new_base = self.repo.commit('docs: main moved', **{'notes.md': 'n2\n', README: readme([ROW_A, ROW_B_MAIN, ROW_C])})
        # The gh/node stubs and environment of MergeGateTests, written into that test's own temporary directory.
        helper = MergeGateTests('test_green_ready_pr_reports_would_allow_without_merging')
        helper.setUp()
        self.addCleanup(helper.doCleanups)
        self.helper_root = helper.root
        self.env = {**helper.env}

    def rebased(self, rows=None, message=None, **extra):
        self.repo.switch(self.new_base)
        rows = [ROW_A_BRANCH, ROW_B_MAIN, ROW_C] if rows is None else rows
        return self.repo.commit(message or self.MESSAGE, **{'App/a.swift': 'a2\n', README: readme(rows), **extra})

    def record(self, head):
        path = self.repo.root / '.build/mado-verify' / f'{head}.json'
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({'issue': 789, 'head': head,
                                    'commentUrl': 'https://github.com/anzchy/mado/issues/789#issuecomment-1'}))

    def gate(self, new_head, text=None, base=None, script=SCRIPT, **extra):
        self.repo.switch(new_head)  # merge-gate finds the PR head through the worktree that has it checked out
        subprocess.run(['git', 'update-ref', 'refs/remotes/origin/main', base or self.new_base], cwd=self.repo.root,
                       check=True)
        self.record(self.old_head)
        view = json.dumps({'headRefOid': new_head, 'isDraft': False, 'createdAt': '2026-01-02T00:00:00Z',
                           'body': body().replace('{sha}', self.old_head[:7]) if text is None else text})
        return subprocess.run(['sh', str(script), '12', '--audited', self.old_head], cwd=self.repo.root,
                              env={**self.env, 'GH_HEAD': new_head, 'GH_VIEW': view, **extra},
                              capture_output=True, text=True)

    def proof(self, new_head, base=None):
        return subprocess.run(['zsh', str(self.repo.root / '.agents/skills/mado-delegator/scripts/rebase-verify.sh'),
                               self.old_base, self.old_head, base or self.new_base, new_head],
                              cwd=self.repo.root, capture_output=True, text=True)

    def trusted(self, output, doc_rows=True):
        """A delegator scripts directory whose own rebase-verify.sh prints `output` (merge-gate trusts its directory)."""
        directory = Path(tempfile.mkdtemp(dir=self.root))
        for name in ('merge-gate.sh', 'main-ci-status.sh') + (('doc_rows.py',) if doc_rows else ()):
            shutil.copy2(SCRIPT.with_name(name), directory / name)
        (directory / 'rebase-verify.sh').write_text("#!/bin/zsh\ncat <<'OUT'\n" + output + "\nOUT\nexit 0\n")
        return directory / 'merge-gate.sh'

    def genuine(self, head):
        proof = self.proof(head)
        self.assertEqual(proof.returncode, 0, proof.stdout + proof.stderr)
        lines = proof.stdout.splitlines()
        verdict = DOCS.match(lines[-1])
        self.assertIsNotNone(verdict, proof.stdout)
        return lines, verdict.group(1), verdict.group(2)

    def assertRefused(self, result, reason):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('would-refuse condition-failed: ', result.stdout)
        self.assertIn(reason, result.stdout)
        self.assertNotIn('would-allow', result.stdout)

    def test_docs_differ_is_accepted_when_every_condition_holds(self):
        head = self.rebased()
        proof = self.proof(head)
        self.assertEqual(proof.returncode, 0, proof.stdout + proof.stderr)
        self.assertIn('CODE same, DOCS differ ', proof.stdout)
        result = self.gate(head)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f'merge-gate: would-allow PR #12 @ {head}', result.stdout)

    def test_docs_differ_with_ledger_limit_text_change_is_accepted(self):
        head = self.rebased(**{'docs/feature-ledger.md': ledger(limit='限制：只有自动测试。')})
        self.assertIn('would-allow', self.gate(head).stdout)

    def test_docs_differ_is_refused_when_a_rebase_verify_condition_fails(self):
        cases = {
            'acceptance text changed': self.rebased(**{'docs/feature-ledger.md': ledger(accept='打开图片即可。')}),
            'path outside the allowlist': self.rebased(**{'notes.md': 'n2 branch\n'}),
            'a lost row edit': self.rebased([ROW_A, ROW_B_MAIN, ROW_C]),
            'messages differ': self.rebased(message='feat: topic'),
        }
        for name, head in cases.items():
            with self.subTest(name):
                self.assertNotEqual(self.proof(head).returncode, 0)
                self.assertRefused(self.gate(head), 'rebase-verify CODE same')

    def test_docs_differ_is_refused_on_upstream_overlap(self):
        self.repo.switch(self.old_base)
        self.old_head = self.repo.commit(self.MESSAGE, **{
            'App/a.swift': 'a2\n', 'App/c.swift': 'c1\nc2\nc3\nc4\nc5\nc6\nc7\nbranch\n',
            README: readme([ROW_A_BRANCH, ROW_B, ROW_C])})
        self.repo.switch(self.old_base)
        upstream = self.repo.commit('feat: main code', **{
            'App/c.swift': 'main\nc2\nc3\nc4\nc5\nc6\nc7\nc8\n', README: readme([ROW_A, ROW_B_MAIN, ROW_C])})
        self.repo.switch(upstream)
        head = self.repo.commit(self.MESSAGE, **{'App/a.swift': 'a2\n', 'App/c.swift': 'main\nc2\nc3\nc4\nc5\nc6\nc7\nbranch\n',
                                                 README: readme([ROW_A_BRANCH, ROW_B_MAIN, ROW_C])})
        self.assertIn('UPSTREAM OVERLAP App/c.swift', self.proof(head, upstream).stdout)
        self.assertRefused(self.gate(head, base=upstream), 'rebase-verify CODE same')

    def test_docs_differ_is_refused_while_a_known_high_is_open(self):
        head = self.rebased()
        sha = self.old_head[:7]
        good = GOOD_AUDIT.replace('{sha}', sha)
        cases = {
            'audit row names an open High': body(audit=f'| audit | PASS | {sha} | one round, 1 High open |'),
            'audit Source names a High besides the phrase': body(
                audit=f'| audit | PASS | {sha} | 1 High open; no Critical/High claimed |'),
            'audit Source names a High in prose': body(
                audit=f'| audit | PASS | {sha} | round 1 F1 High still open; otherwise no Critical/High |'),
            'audit Source counts lowercase highs': body(audit=f'| audit | PASS | {sha} | no Critical/High; 2 highs deferred |'),
            'audit Source counts zero Critical': body(audit=f'| audit | PASS | {sha} | 0 Critical, no Critical/High |'),
            'Still open names a High': body(still_open='- High: the replay loses a row (owner decision pending).'),
            'Still open names a Critical': body(still_open='- Critical: data loss on rebase.'),
            'Still open mixed case': body(still_open='- hIgH: unresolved'),
            'Still open lowercase count': body(still_open='- 1 high open'),
            'Still open upper case': body(still_open='- HIGH: replay loses a row'),
            'Still open plural': body(still_open='- 2 Highs deferred'),
            'Still open as a label': body(heading='Still open:', still_open='- High: replay loses a row'),
            'Still open in bold': body(heading='**Still open**', still_open='- High: replay loses a row'),
            'Still open missing': body(heading='### Notes'),
            'Still open as an h1': body(heading='# Still open'),
            'Still open as an h4': body(heading='#### Still open'),
            'a second Still open section': body(extra='## Still open (2)\n- Medium: another note\n'),
            'a subheading inside Still open hides a High': body(
                still_open='- Medium: note\n#### Details\n- High: replay loses a row'),
            'a fenced heading inside Still open hides a High': body(
                still_open='- Medium: note\n```\n## not a heading\n```\n- High: replay loses a row'),
            'two audit rows': body(audit=good + f'\n| audit | FAIL | {sha} | round 2 found 1 High |'),
            'a second Gates section': body(extra=f'## Gates\n\n| Lane | Status | SHA | Source |\n| --- | --- | --- | --- |\n'
                                                f'| audit | FAIL | {sha} | 1 High |\n'),
            'a Still open label under another heading': body(extra='## Notes\nStill open:\n- High: replay loses a row\n'),
            'a second Gates heading without an audit row': body(extra='## Gates (round 2)\n- see the audit report\n'),
            'a word that only contains High fails closed': body(still_open='- Medium: High-DPI icons blur'),
            'audit row not PASS': body(audit=f'| audit | NOT VERIFIED | {sha} | auditor paused; no Critical/High known |'),
            'no audit row': body(audit=f'| node-tooling | PASS | {sha} | node 10/10 |'),
            'no Gates table': '## Summary\n\nx\n',
        }
        for name, text in cases.items():
            with self.subTest(name):
                self.assertRefused(self.gate(head, text=text.replace('{sha}', sha)), 'known High')

    def test_docs_differ_accepts_the_canonical_still_open_forms(self):
        head = self.rebased()
        sha = self.old_head[:7]
        for name, text in {
            'h2 Still open': body(heading='## Still open'),
            'lowercase heading': body(heading='### still open'),
            'nothing open': body(still_open='- none'),
            'bare phrase': body(audit=f'| audit | PASS | {sha} | no Critical/High |'),
        }.items():
            with self.subTest(name):
                self.assertIn('would-allow', self.gate(head, text=text.replace('{sha}', sha)).stdout)

    def test_a_pr_head_copy_of_rebase_verify_is_never_run(self):
        head = self.rebased(**{'notes.md': 'n2 branch\n'})  # genuinely CODE differ (notes.md is outside the allowlist)
        forged = self.repo.root / '.agents/skills/mado-delegator/scripts/rebase-verify.sh'
        forged.write_text("#!/bin/zsh\nprint -r -- 'MESSAGES same'\nprint -r -- 'CODE same "
                          + '1' * 40 + " (exact replayed tree match; candidate patch " + '2' * 40 + ")'\nexit 0\n")
        self.assertRefused(self.gate(head), 'rebase-verify CODE same')

    def test_the_verdict_line_must_match_its_grammar_and_bind_to_both_patches(self):
        head = self.rebased()
        lines, old, new = self.genuine(head)
        before = '\n'.join(lines[:-1])
        unrelated = '1' * 40
        self.assertIn('would-allow', self.gate(head, script=self.trusted('\n'.join(lines))).stdout)
        for name, verdict in {
            'plain CODE same with an unrelated hash and trailing text': f'CODE same {unrelated} extra',
            'plain CODE same with trailing text': f'CODE same {old} (exact replayed tree match; candidate patch {new}) extra',
            'plain CODE same with an unrelated audited hash':
                f'CODE same {unrelated} (exact replayed tree match; candidate patch {new})',
            'plain CODE same with an unrelated candidate hash':
                f'CODE same {old} (exact replayed tree match; candidate patch {unrelated})',
            'DOCS differ with an unrelated hash and trailing text': f'CODE same, DOCS differ {unrelated} extra',
            'DOCS differ with trailing text': lines[-1] + ' extra',
            'DOCS differ with an unrelated audited hash': lines[-1].replace(old, unrelated),
            'DOCS differ with an unrelated candidate hash': lines[-1].replace(new, unrelated),
            'a short hash': lines[-1].replace(old, old[:7]),
        }.items():
            with self.subTest(name):
                self.assertRefused(self.gate(head, script=self.trusted(before + '\n' + verdict)), 'rebase-verify')

    def test_a_docs_verdict_is_checked_against_mains_allowlist(self):
        head = self.rebased()
        lines, old, new = self.genuine(head)
        verdict = lines[-1]
        kept = [line for line in lines[:-1] if not line.startswith('DIFF ')]
        for name, output in {
            'path outside the allowlist': kept + ['DIFF App/a.swift', verdict],
            'no differing path': kept + [verdict],
            'a refusal line': lines[:-1] + ['UPSTREAM OVERLAP App/a.swift', verdict],
            'two verdicts': lines[:-1] + [f'CODE same {old} (exact replayed tree match; candidate patch {new})', verdict],
        }.items():
            with self.subTest(name):
                self.assertRefused(self.gate(head, script=self.trusted('\n'.join(output))), 'rebase-verify')

    def test_a_failed_allowlist_lookup_is_lookup_failed_and_keeps_the_override(self):
        head = self.rebased()
        lines, _, _ = self.genuine(head)
        result = self.gate(head, script=self.trusted('\n'.join(lines), doc_rows=False),
                           MADO_MERGE_GATE_OVERRIDE='owner accepted the docs rebase', HOME=str(self.root))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('would-refuse lookup-failed: ', result.stdout)
        self.assertIn('doc_rows', result.stdout)
        self.assertIn('override recorded', result.stdout)
        self.assertIn('owner accepted the docs rebase',
                      (self.root / '.mado/handoff/merge-gate-overrides.log').read_text())

    def test_the_real_pr_body_lint_accepts_the_documented_audit_row(self):
        head = self.rebased()
        sha = self.old_head[:7]
        ok = self.gate(head, text=lint_body(f'CODE same {self.old_head}; two rounds, no Critical/High open', sha),
                       NODE_REAL_LINT='1')
        self.assertEqual(ok.returncode, 0, ok.stdout + ok.stderr)
        self.assertIn(f'merge-gate: would-allow PR #12 @ {head}', ok.stdout)
        quoted = self.gate(head, text=lint_body(f'CODE same, DOCS differ {self.old_head}; no Critical/High', sha),
                           NODE_REAL_LINT='1')
        self.assertRefused(quoted, 'PR body lint failed: audit PASS has a stale head without CODE same evidence')


if __name__ == '__main__':
    unittest.main()
