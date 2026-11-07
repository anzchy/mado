"""Offline tests for panel-choose.sh: pasteboard path entry with fake pbcopy/pbpaste/osascript/kc.sh/sleep."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
HELPER = ROOT / '.agents/skills/picsee-delegator/scripts/panel-choose.sh'
PINYIN = 'com.bytedance.inputmethod.doubaoime.pinyin'
KEYS = [['5', 'command', 'shift'], ['0', 'command'], ['9', 'command'], ['36'], ['36']]
FORBIDDEN = ('keystroke', 'TISSelectInputSource', 'TISEnableInputSource', 'TISDisableInputSource',
             'TISSetInputMethodKeyboardLayoutOverride', 'defaults write', 'clearContents', 'setString')

# One fake for every tool; it dispatches on its own name and logs each call as a JSON line.
FAKE = r'''
import json, os, signal, sys
from pathlib import Path
state = Path(os.environ['FAKE_STATE'])
clip = state / 'clip'
name = Path(sys.argv[0]).name
def log(**event):
    with open(state / 'log.jsonl', 'a') as f:
        f.write(json.dumps(dict(tool=name, **event)) + '\n')
def count():
    path = state / ('count-' + name)
    n = int(path.read_text()) + 1 if path.exists() else 1
    path.write_text(str(n))
    return n
def nth(var, n):
    return os.environ.get(var, '') == str(n)
def signal_parent(var, n):
    sent = os.environ.get(var, '')
    if sent.split(':')[0] == str(n):
        os.kill(os.getppid(), getattr(signal, 'SIG' + sent.split(':')[1]))
if name == 'pbpaste':
    n = count()
    log(n=n)
    signal_parent('FAKE_PBPASTE_SIGNAL', n)
    if nth('FAKE_PBPASTE_FAIL', n):
        sys.exit(1)
    sys.stdout.buffer.write(clip.read_bytes())
elif name == 'pbcopy':
    n = count()
    data = sys.stdin.buffer.read()
    log(n=n, data=data.hex())
    if nth('FAKE_PBCOPY_FAIL', n):
        sys.exit(1)
    signal_parent('FAKE_PBCOPY_SIGNAL', n)
    clip.write_bytes(data + (b'\n' if nth('FAKE_PBCOPY_CORRUPT', n) else b''))
    changes = state / 'changes'
    changes.write_text(str(int(changes.read_text()) + 1 if changes.exists() else 1))
elif name == 'sleep':
    log(n=count(), args=sys.argv[1:])
    signal_parent('FAKE_SLEEP_SIGNAL', int((state / 'count-sleep').read_text()))
elif name == 'osascript':
    argv = sys.argv[1:]
    log(argv=argv)
    script = '\n'.join(argv)
    if 'TISCopyCurrentKeyboardInputSource' in script:
        if os.environ.get('FAKE_INPUT_SOURCE_FAIL'):
            print('execution error: no input source', file=sys.stderr)
            sys.exit(1)
        print(os.environ.get('FAKE_INPUT_SOURCE', 'com.apple.keylayout.ABC'))
    elif 'NSPasteboard' in script and 'changeCount' in script and 'types' not in script:
        n = count()
        if nth('FAKE_COUNT_FAIL', n):
            print('execution error: pasteboard unavailable', file=sys.stderr)
            sys.exit(1)
        changes = state / 'changes'
        print((int(changes.read_text()) if changes.exists() else 0) + (n if os.environ.get('FAKE_CHANGE_DURING_SAVE') else 0))
    elif 'NSPasteboard' in script and 'types' in script:
        if os.environ.get('FAKE_TYPES_FAIL'):
            print('execution error: pasteboard unavailable', file=sys.stderr)
            sys.exit(1)
        types = os.environ.get('FAKE_TYPES')
        if types is None:
            types = 'public.utf8-plain-text\nNSStringPboardType' if clip.read_bytes() else ''
        print(0)
        if types:
            print(types)
    else:
        sys.exit(1)
elif name == 'kc.sh':
    n = count()
    tmp = Path(os.environ['TMPDIR'])
    modes = sorted(oct(p.stat().st_mode & 0o777) for p in tmp.rglob('*') if p.is_file())
    log(n=n, args=sys.argv[2:], run=sys.argv[1], clip=clip.read_bytes().hex(), modes=modes)
    if nth('FAKE_KC_USER_COPY', n):
        clip.write_bytes(b'user copy')
        changes = state / 'changes'
        changes.write_text(str(int(changes.read_text()) + 1 if changes.exists() else 1))
    signal_parent('FAKE_KC_SIGNAL', n)
    if nth('FAKE_KC_FAIL', n):
        print('FAIL input — fake', file=sys.stderr)
        sys.exit(1)
'''


class PanelChoose(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='mado-panel-')
        self.addCleanup(self.temp.cleanup)
        base = Path(self.temp.name).resolve()
        self.repo, self.state, self.bin, self.tmp = (base / n for n in ('repo', 'state', 'bin', 'tmp'))
        for d in (self.state, self.bin, self.tmp):
            d.mkdir()
        helper = self.repo / '.agents/skills/picsee-delegator/scripts/panel-choose.sh'
        helper.parent.mkdir(parents=True)
        shutil.copy(HELPER, helper)
        self.helper = helper
        subprocess.run(['git', 'init', '-q', str(self.repo)], check=True)
        fake = base / 'fake.py'
        fake.write_text(FAKE)
        tools = [self.bin / t for t in ('pbcopy', 'pbpaste', 'osascript', 'sleep')]
        tools.append(self.repo / 'scripts/device/kc.sh')
        tools[-1].parent.mkdir(parents=True)
        for tool in tools:
            tool.write_text(f'#!{sys.executable}\nexec(open({str(fake)!r}).read())\n')
            tool.chmod(0o755)

    def run_helper(self, path, clip=b'old clip\n', args=None, **env):
        (self.state / 'clip').write_bytes(clip)
        environment = dict(PATH=f'{self.bin}:/usr/bin:/bin', HOME=self.temp.name, TMPDIR=str(self.tmp),
                           FAKE_STATE=str(self.state), **env)
        argv = ['/bin/zsh', str(self.helper), *(['RUN'] + [path] if args is None else args)]
        result = subprocess.run(argv, env=environment, capture_output=True, timeout=30)
        self.log = [json.loads(line) for line in (self.state / 'log.jsonl').read_text().splitlines()] \
            if (self.state / 'log.jsonl').exists() else []
        self.out = result.stdout.decode()
        self.err = result.stderr.decode()
        self.assertNoKeystroke(path)
        self.assertEqual(list(self.tmp.iterdir()), [], 'helper left temp files behind')
        for call in self.calls('kc.sh'):
            self.assertTrue(set(call['modes']) <= {'0o600'}, call['modes'])
        self.assertLessEqual(len(self.calls('pbcopy')), 2, 'set once, restore once')
        return result.returncode

    def calls(self, tool):
        return [e for e in self.log if e['tool'] == tool]

    def keys(self):
        return [e['args'] for e in self.calls('kc.sh')]

    def clip(self):
        return (self.state / 'clip').read_bytes()

    def assertNoKeystroke(self, path):
        for call in self.calls('osascript'):
            script = '\n'.join(call['argv'])
            for word in FORBIDDEN:
                self.assertNotIn(word, script)
            if path:
                self.assertNotIn(path, script)

    def pasted(self):
        return bytes.fromhex(next(e['clip'] for e in self.calls('kc.sh') if e['args'] == ['9', 'command']))

    def test_success_pastes_path_restores_pasteboard_and_keeps_timing(self):
        path = '/Users/jack/.picsee/device-runs/20261025-095720-p301-grid-explore/fixtures/grid'
        self.assertEqual(self.run_helper(path), 0, self.err)
        self.assertEqual(self.keys(), KEYS)
        self.assertTrue(all(e['run'] == 'RUN' for e in self.calls('kc.sh')))
        self.assertEqual(self.pasted(), path.encode())
        self.assertEqual(self.clip(), b'old clip\n')
        self.assertEqual([e['args'] for e in self.calls('sleep')], [['1.2'], ['1.2'], ['1.5'], ['2.5']])
        # the last pasteboard write is the restore, and it is read back afterwards
        writes = self.calls('pbcopy')
        self.assertEqual(bytes.fromhex(writes[-1]['data']), b'old clip\n')
        self.assertGreater(self.log.index(self.calls('pbpaste')[-1]), self.log.index(writes[-1]))
        self.assertGreater(self.log.index(writes[-1]), self.log.index(self.calls('kc.sh')[-1]))
        self.assertGreater(self.log.index(writes[-1]), self.log.index(self.calls('sleep')[-1]))
        self.assertEqual(len(writes), 2)

    def test_trailing_newlines_and_binary_bytes_restore_exactly(self):
        for clip in (b'clip', b'clip\n\n', b'\n', b'tab\tcr\r\n\xe8\xb7\x91'):
            with self.subTest(clip=clip):
                for f in self.state.iterdir():
                    f.unlink()
                self.assertEqual(self.run_helper('/tmp/x', clip=clip), 0, self.err)
                self.assertEqual(self.clip(), clip)
                self.assertEqual(self.pasted(), b'/tmp/x')

    def test_copy_between_type_check_and_save_refuses_before_touching(self):
        self.assertNotEqual(self.run_helper('/tmp/x', FAKE_CHANGE_DURING_SAVE='1'), 0)
        self.assertEqual(self.calls('pbcopy'), [])
        self.assertEqual(self.keys(), [])
        self.assertIn('pasteboard changed', self.err)

    def test_copy_during_the_keys_is_never_overwritten(self):
        # The user copies while the helper holds the pasteboard: their copy wins, and the run fails loudly.
        for at in range(1, 6):
            with self.subTest(at=at):
                for f in self.state.iterdir():
                    f.unlink()
                self.assertEqual(self.run_helper('/tmp/x', FAKE_KC_USER_COPY=str(at)), 1)
                self.assertEqual(self.keys(), KEYS)
                self.assertEqual(self.clip(), b'user copy')
                self.assertEqual(len(self.calls('pbcopy')), 1, 'no restore over the newer copy')
                self.assertIn('pasteboard changed by someone else', self.err)
                self.assertIn('not restored', self.err)

    def test_copy_during_the_keys_then_failure_or_interrupt_is_not_overwritten(self):
        for env, code in ((dict(FAKE_KC_USER_COPY='2', FAKE_KC_FAIL='3'), 1),
                          (dict(FAKE_KC_USER_COPY='2', FAKE_KC_SIGNAL='3:INT'), 130)):
            with self.subTest(env=env):
                for f in self.state.iterdir():
                    f.unlink()
                self.assertEqual(self.run_helper('/tmp/x', **env), code, self.err)
                self.assertEqual(self.clip(), b'user copy')
                self.assertEqual(len(self.calls('pbcopy')), 1)
                self.assertIn('not restored', self.err)

    def test_unreadable_change_count_after_set_or_at_restore_fails_loudly(self):
        # changeCount reads: 1 = re-check after save, 2 = after setting the path, 3 = before restoring.
        self.assertEqual(self.run_helper('/tmp/x', FAKE_COUNT_FAIL='2'), 1)
        self.assertEqual(self.keys(), [])
        self.assertEqual(self.clip(), b'old clip\n')
        self.assertIn('nothing pasted', self.err)
        for f in self.state.iterdir():
            f.unlink()
        self.assertEqual(self.run_helper('/tmp/x', FAKE_COUNT_FAIL='3'), 1)
        self.assertEqual(self.keys(), KEYS)
        self.assertEqual(self.clip(), b'/tmp/x')
        self.assertIn('not restored', self.err)

    def test_unreadable_pasteboard_refuses_before_touching(self):
        self.assertNotEqual(self.run_helper('/tmp/x', FAKE_PBPASTE_FAIL='1'), 0)
        self.assertEqual(self.calls('pbcopy'), [])
        self.assertEqual(self.keys(), [])
        self.assertIn('pasteboard', self.err)

    def test_several_plain_text_types_are_accepted(self):
        types = 'public.utf8-plain-text\npublic.utf16-plain-text\npublic.utf16-external-plain-text\nNSStringPboardType'
        self.assertEqual(self.run_helper('/tmp/x', FAKE_TYPES=types), 0, self.err)
        self.assertEqual(self.keys(), KEYS)

    def test_awkward_paths_arrive_byte_intact(self):
        for path in ('/tmp/a b/c d', '/Users/x/跑01 图片/grid、fixtures', '/tmp/it\'s "quoted"/x',
                     '/tmp/$(touch pwned)/`id`/\\n back\\slash', '/tmp/trailing space ', '-n'):
            with self.subTest(path=path):
                for f in self.state.iterdir():
                    f.unlink()
                self.assertEqual(self.run_helper(path), 0, self.err)
                self.assertEqual(self.pasted(), path.encode())
                self.assertEqual(self.clip(), b'old clip\n')
                self.assertFalse((self.repo / 'pwned').exists())

    def test_empty_pasteboard_restored_empty(self):
        self.assertEqual(self.run_helper('/tmp/x', clip=b''), 0, self.err)
        self.assertEqual(self.pasted(), b'/tmp/x')
        self.assertEqual(self.clip(), b'')
        self.assertEqual(self.calls('pbcopy')[-1]['data'], '')

    def test_failed_key_stops_sequence_and_restores(self):
        for failing in range(1, 6):
            with self.subTest(failing=failing):
                for f in self.state.iterdir():
                    f.unlink()
                self.assertNotEqual(self.run_helper('/tmp/x', FAKE_KC_FAIL=str(failing)), 0)
                self.assertEqual(self.keys(), KEYS[:failing])
                self.assertEqual(self.clip(), b'old clip\n')

    def test_restore_mismatch_exits_nonzero(self):
        self.assertNotEqual(self.run_helper('/tmp/x', FAKE_PBCOPY_CORRUPT='2'), 0)
        self.assertEqual(self.keys(), KEYS)
        self.assertIn('pasteboard restore', self.err)
        self.assertIn('differ', self.err)

    def test_restore_write_failure_exits_nonzero(self):
        self.assertNotEqual(self.run_helper('/tmp/x', FAKE_PBCOPY_FAIL='2'), 0)
        self.assertIn('pasteboard restore', self.err)

    def test_unverified_path_is_never_pasted(self):
        self.assertNotEqual(self.run_helper('/tmp/x', FAKE_PBCOPY_CORRUPT='1'), 0)
        self.assertNotIn(['9', 'command'], self.keys())
        self.assertNotIn(['36'], self.keys())
        self.assertEqual(self.clip(), b'old clip\n')

    def test_interrupt_restores_pasteboard(self):
        codes = dict(INT=130, TERM=143, HUP=129)
        points = (('FAKE_KC_SIGNAL', '2', 2), ('FAKE_SLEEP_SIGNAL', '2', 3), ('FAKE_PBPASTE_SIGNAL', '1', 0),
                  ('FAKE_PBCOPY_SIGNAL', '1', 0))
        for sig, code in codes.items():
            for var, n, keys_sent in points:
                with self.subTest(sig=sig, at=var):
                    for f in self.state.iterdir():
                        f.unlink()
                    self.assertEqual(self.run_helper('/tmp/x', **{var: n + ':' + sig}), code, self.err)
                    self.assertEqual(self.keys(), KEYS[:keys_sent])
                    self.assertEqual(self.clip(), b'old clip\n')

    def test_non_text_pasteboard_or_unreadable_types_refuse_before_touching(self):
        for env in (dict(FAKE_TYPES='public.png\npublic.utf8-plain-text'), dict(FAKE_TYPES_FAIL='1')):
            with self.subTest(env=env):
                for f in self.state.iterdir():
                    f.unlink()
                self.assertNotEqual(self.run_helper('/tmp/x', **env), 0)
                self.assertEqual(self.calls('pbcopy'), [])
                self.assertEqual(self.keys(), [])
                self.assertIn('pasteboard', self.err)
        self.assertIn('public.png', self.run_and_err(FAKE_TYPES='public.png'))

    def run_and_err(self, **env):
        for f in self.state.iterdir():
            f.unlink()
        self.run_helper('/tmp/x', **env)
        return self.err

    def test_usage_errors_touch_nothing(self):
        for args in ([], ['RUN'], ['RUN', '/tmp/x', 'extra'], ['RUN', '']):
            with self.subTest(args=args):
                self.assertEqual(self.run_helper('', args=args), 2)
                self.assertEqual(self.calls('pbcopy'), [])
                self.assertEqual(self.keys(), [])

    def test_reports_active_input_source_read_only(self):
        self.assertEqual(self.run_helper('/tmp/x', FAKE_INPUT_SOURCE=PINYIN), 0, self.err)
        self.assertIn('input-source: ' + PINYIN, self.out.splitlines())
        reads = [c for c in self.calls('osascript') if 'TISCopyCurrentKeyboardInputSource' in '\n'.join(c['argv'])]
        self.assertEqual(len(reads), 1)
        self.assertLess(self.log.index(reads[0]), self.log.index(self.calls('kc.sh')[0]))

    def test_input_source_reader_failure_is_reported_and_run_continues(self):
        self.assertEqual(self.run_helper('/tmp/x', FAKE_INPUT_SOURCE_FAIL='1'), 0, self.err)
        self.assertTrue(any(l.startswith('input-source: unknown') for l in self.out.splitlines()), self.out)
        self.assertEqual(self.keys(), KEYS)


if __name__ == '__main__':
    unittest.main()
