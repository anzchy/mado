import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace


SCRIPT = Path(__file__).with_name('push-guard.py')
spec = importlib.util.spec_from_file_location('push_guard', SCRIPT)
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


class PushGuardTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'scripts/codex-rules').mkdir(parents=True)
        (self.root / '.codex/rules').mkdir(parents=True)
        self.overlay = self.root / '.codex/rules/picsee-role.rules'
        self.overlay.write_text('# Local picsee role: delegator\n')
        self.branch = 'fix/topic'
        self.remotes = ['https://github.com/anzchy/picsee.git']

    def invoke(self, *args):
        def fake_git(*argv):
            if argv == ('rev-parse', '--show-toplevel'):
                return str(self.root)
            if argv == ('symbolic-ref', '--quiet', '--short', 'HEAD'):
                return self.branch
            if argv == ('remote', 'get-url', '--push', 'origin'):
                return self.remotes[0]
            if argv == ('remote', 'get-url', '--push', '--all', 'origin'):
                return '\n'.join(self.remotes)
            raise AssertionError(argv)

        with patch.object(guard, '__file__', str(self.root / 'scripts/codex-rules/push-guard.py')):
            with patch.object(guard, 'git', side_effect=fake_git):
                with patch.object(guard.subprocess, 'run', return_value=SimpleNamespace(returncode=0)) as run:
                    with patch.object(sys, 'argv', ['push-guard.py', *args]):
                        result = guard.main()
        return result, run

    def test_ordinary_push_is_current_topic_branch_only(self):
        result, run = self.invoke('--dry-run')
        self.assertEqual(result, 0)
        run.assert_called_once_with(['git', 'push', '--dry-run', self.remotes[0],
                                     'HEAD:refs/heads/fix/topic'], check=False)

    def test_rebased_push_requires_exact_lease_oid(self):
        oid = 'a' * 40
        result, run = self.invoke('--expected-remote-oid', oid)
        self.assertEqual(result, 0)
        run.assert_called_once_with(['git', 'push',
                                     f'--force-with-lease=refs/heads/fix/topic:{oid}',
                                     self.remotes[0], 'HEAD:refs/heads/fix/topic'], check=False)

    def test_rejects_restricted_role_main_and_wrong_remote(self):
        for setup in [
            lambda: self.overlay.write_text('# Local picsee role: implementor\n'),
            lambda: setattr(self, 'branch', 'main'),
            lambda: setattr(self, 'remotes', ['https://example.com/other.git']),
        ]:
            self.overlay.write_text('# Local picsee role: delegator\n')
            self.branch = 'fix/topic'
            self.remotes = ['https://github.com/anzchy/picsee.git']
            setup()
            with self.assertRaises(SystemExit):
                self.invoke()

    def test_accepts_exactly_one_picsee_or_mado_push_url(self):
        # #554: the repo is renamed anzchy/picsee -> anzchy/mado; both names stay pushable.
        for url in ['https://github.com/anzchy/picsee.git', 'git@github.com:anzchy/picsee.git',
                    'https://github.com/anzchy/mado.git', 'git@github.com:anzchy/mado.git']:
            self.remotes = [url]
            try:
                result, run = self.invoke('--dry-run')
            except SystemExit:
                self.fail(f'{url} was refused')
            self.assertEqual(result, 0, url)
            run.assert_called_once_with(['git', 'push', '--dry-run', url, 'HEAD:refs/heads/fix/topic'], check=False)

    def test_rejects_near_miss_push_urls(self):
        for remotes in [
            ['https://github.com/other/mado.git'], ['git@github.com:other/mado.git'],
            ['https://github.com/anzchy/mado-foo.git'], ['git@github.com:anzchy/mado-foo.git'],
            ['https://github.com/anzchy/other.git'], ['http://github.com/anzchy/mado.git'],
            ['https://github.com/anzchy/mado'], ['git@github.com:anzchy/mado'],
            ['https://github.com/anzchy/mado.git/'], ['https://github.com/anzchy/Mado.git'],
            ['ssh://git@github.com/anzchy/mado.git'], [' https://github.com/anzchy/mado.git'],
            ['https://github.com/anzchy/mado.git', 'git@github.com:anzchy/mado.git'],
            ['https://github.com/anzchy/picsee.git', 'https://github.com/anzchy/mado.git'],
            [],
        ]:
            self.remotes = remotes
            with self.subTest(remotes=remotes), self.assertRaises(SystemExit):
                self.invoke()

    def test_rejects_malformed_lease(self):
        with self.assertRaises(SystemExit):
            self.invoke('--expected-remote-oid', 'not-an-oid')

    def test_rejects_second_push_destination_before_running_push(self):
        self.remotes.append('https://example.invalid/unapproved.git')
        with self.assertRaises(SystemExit):
            self.invoke()


if __name__ == '__main__':
    unittest.main()
