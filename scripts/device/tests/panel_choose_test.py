"""Offline contract tests for the current AX panel helper; never access a real desktop."""
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
KEYS = [['5', 'command', 'shift'], ['36'], ['36']]

# This fake models panel state, not expected test outcomes. AX readback decodes the
# actual AppleScript string written by the real shell helper. Commands for the
# wrong process never see the panel. Clipboard tools are traps, not real tools.
FAKE = r'''
import json, os, re, sys
from pathlib import Path
root = Path(os.environ['FAKE_STATE'])
path = root / 'state.json'
state = json.loads(path.read_text())
name = Path(sys.argv[0]).name
args = sys.argv[1:]
def save():
    path.write_text(json.dumps(state))
def event(**data):
    with (root / 'log.jsonl').open('a') as stream:
        stream.write(json.dumps(dict(tool=name, **data)) + '\n')
def fail(message):
    print(message, file=sys.stderr)
    sys.exit(1)
if name in ('pbcopy', 'pbpaste'):
    event(args=args)
    fail('clipboard access forbidden')
elif name == 'sleep':
    event(args=args)
elif name == 'kc.sh':
    keys = args[1:]
    state['keys'].append(keys)
    event(run=args[0], args=keys)
    save()
    if len(state['keys']) == int(os.environ.get('FAKE_KEY_FAIL', '0')):
        fail('fake key failure')
    if keys == ['5', 'command', 'shift']:
        if not os.environ.get('FAKE_GO_OPEN_TIMEOUT'):
            state['sheets'] = 1
    elif keys == ['36'] and state['sheets'] == 1:
        if not os.environ.get('FAKE_GO_CLOSE_TIMEOUT'):
            state['sheets'] = 0
    elif keys == ['36'] and state['panel_open']:
        if not os.environ.get('FAKE_PANEL_CLOSE_TIMEOUT'):
            state['selected'] = state['field']
            state['panel_open'] = False
    elif keys == ['53']:
        state['cancelled'] = True
    save()
elif name == 'osascript':
    script = args[-1]
    event(args=args, script=script)
    if 'TISCopyCurrentKeyboardInputSource' in script:
        if os.environ.get('FAKE_SOURCE_FAIL'):
            fail('fake input source unavailable')
        print(os.environ.get('FAKE_INPUT_SOURCE', 'com.apple.keylayout.ABC'))
        sys.exit(0)
    match = re.search(r'first process whose unix id is ([0-9]+)', script)
    if not match or match.group(1) != '4242':
        print('false')
        sys.exit(0)
    if 'return count of sheets' in script:
        print(state['sheets'])
    elif 'set value of text field 1 of sheet 1 to ' in script:
        literal = re.search(r'to "((?:\\.|[^"\\])*)"$', script, re.S)
        if not literal:
            fail('malformed AX string literal')
        state['field'] = re.sub(r'\\([\\"])', r'\1', literal.group(1))
        save()
    elif 'return value of text field 1 of sheet 1' in script:
        if os.environ.get('FAKE_READ_FAIL'):
            fail('fake AX read unavailable')
        print('/wrong/path' if os.environ.get('FAKE_READ_MISMATCH') else state['field'])
    elif 'return exists' in script:
        dialog = 'subrole is "AXDialog"' in script
        supported = state['mode'] == ('dialog' if dialog else 'sheet')
        print('true' if supported and state['panel_open'] else 'false')
    else:
        fail('unexpected AX command: ' + script)
else:
    fail('unexpected fake tool: ' + name)
'''


class PanelChoose(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='mado-panel-')
        self.addCleanup(self.temp.cleanup)
        base = Path(self.temp.name).resolve()
        self.repo, self.state, self.bin = (base / name for name in ('repo', 'state', 'bin'))
        self.state.mkdir()
        self.bin.mkdir()
        self.helper = self.repo / '.agents/skills/picsee-delegator/scripts/panel-choose.sh'
        self.helper.parent.mkdir(parents=True)
        shutil.copy(HELPER, self.helper)
        subprocess.run(['git', 'init', '-q', str(self.repo)], check=True)
        self.run = self.repo / 'RUN'
        self.run.mkdir()
        fake = base / 'fake.py'
        fake.write_text(FAKE)
        tools = [self.bin / name for name in ('osascript', 'sleep', 'pbcopy', 'pbpaste')]
        tools.append(self.repo / 'scripts/device/kc.sh')
        tools[-1].parent.mkdir(parents=True)
        for tool in tools:
            tool.write_text(f'#!{sys.executable}\nexec(open({str(fake)!r}).read())\n')
            tool.chmod(0o755)

    def run_helper(self, target='/tmp/x', *, pid='4242\n', mode='dialog', args=None, **env):
        pidfile = self.run / 'picsee.pid'
        if pid is None:
            pidfile.unlink(missing_ok=True)
        else:
            pidfile.write_text(pid)
        (self.state / 'state.json').write_text(json.dumps(dict(
            mode=mode, panel_open=mode != 'none', sheets=0, field=None,
            selected=None, cancelled=False, keys=[])))
        (self.state / 'log.jsonl').unlink(missing_ok=True)
        environment = dict(PATH=f'{self.bin}:/usr/bin:/bin', HOME=self.temp.name,
                           FAKE_STATE=str(self.state), **env)
        argv = ['/bin/zsh', str(self.helper), *(['RUN', target] if args is None else args)]
        result = subprocess.run(argv, env=environment, capture_output=True, text=True, timeout=30)
        self.out, self.err = result.stdout, result.stderr
        self.snapshot = json.loads((self.state / 'state.json').read_text())
        log = self.state / 'log.jsonl'
        self.log = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
        self.assertEqual(self.calls('pbcopy') + self.calls('pbpaste'), [])
        for call in self.calls('osascript'):
            for forbidden in ('keystroke', 'TISSelectInputSource', 'TISEnableInputSource',
                              'TISDisableInputSource', 'TISSetInputMethodKeyboardLayoutOverride',
                              'defaults write', 'NSPasteboard'):
                self.assertNotIn(forbidden, call['script'])
        return result.returncode

    def calls(self, tool):
        return [event for event in self.log if event['tool'] == tool]

    def assertRefused(self):
        self.assertNotIn('chose:', self.out)
        self.assertIsNone(self.snapshot['selected'])

    def test_dialog_selection_closes_panel_with_verified_target(self):
        self.assertEqual(self.run_helper('/tmp/a b'), 0, self.err)
        self.assertIn('panel: first window whose subrole is "AXDialog"', self.out)
        self.assertIn('chose: /tmp/a b', self.out)
        self.assertEqual(self.snapshot['field'], '/tmp/a b')
        self.assertEqual(self.snapshot['selected'], '/tmp/a b')
        self.assertEqual(self.snapshot['keys'], KEYS)
        self.assertEqual(self.snapshot['sheets'], 0)
        self.assertFalse(self.snapshot['panel_open'])
        self.assertTrue(all(call['run'] == 'RUN' for call in self.calls('kc.sh')))

    def test_window_sheet_selection_closes_panel_with_verified_target(self):
        self.assertEqual(self.run_helper(mode='sheet'), 0, self.err)
        self.assertIn('panel: sheet 1 of window 1', self.out)
        self.assertEqual(self.snapshot['selected'], '/tmp/x')
        self.assertFalse(self.snapshot['panel_open'])
        self.assertEqual(self.snapshot['keys'], KEYS)

    def test_missing_or_malformed_pid_refuses_before_external_actions(self):
        for pid in (None, '', 'not-a-pid', '42x'):
            with self.subTest(pid=pid):
                self.assertNotEqual(self.run_helper(pid=pid), 0)
                self.assertIn('picsee.pid', self.err)
                self.assertEqual(self.log, [])
                self.assertRefused()

    def test_wrong_numeric_pid_cannot_address_owned_panel(self):
        self.assertNotEqual(self.run_helper(pid='4243\n'), 0)
        self.assertIn('no open panel', self.err)
        self.assertEqual(self.snapshot['keys'], [])
        self.assertIsNone(self.snapshot['field'])
        self.assertRefused()

    def test_usage_errors_touch_nothing(self):
        for args in ([], ['RUN'], ['RUN', '/tmp/x', 'extra'], ['RUN', '']):
            with self.subTest(args=args):
                self.assertEqual(self.run_helper(args=args), 2)
                self.assertIn('usage:', self.err)
                self.assertEqual(self.log, [])
                self.assertRefused()

    def test_absent_panel_is_refused_before_keys_or_field_write(self):
        self.assertNotEqual(self.run_helper(mode='none'), 0)
        self.assertIn('no open panel', self.err)
        self.assertEqual(self.snapshot['keys'], [])
        self.assertIsNone(self.snapshot['field'])
        self.assertRefused()

    def test_field_mismatch_or_read_error_cancels_without_confirming(self):
        for fault in ('FAKE_READ_MISMATCH', 'FAKE_READ_FAIL'):
            with self.subTest(fault=fault):
                self.assertNotEqual(self.run_helper(**{fault: '1'}), 0)
                self.assertIn('nothing chosen', self.err)
                self.assertEqual(self.snapshot['keys'], [KEYS[0], ['53']])
                self.assertTrue(self.snapshot['cancelled'])
                self.assertRefused()

    def test_go_to_sheet_open_timeout_prevents_field_write(self):
        self.assertNotEqual(self.run_helper(FAKE_GO_OPEN_TIMEOUT='1'), 0)
        self.assertIn('Go-to sheet did not open', self.err)
        self.assertEqual(self.snapshot['keys'], KEYS[:1])
        self.assertIsNone(self.snapshot['field'])
        self.assertEqual(len(self.calls('sleep')), 20)
        self.assertRefused()

    def test_go_to_sheet_close_timeout_cancels_before_open(self):
        self.assertNotEqual(self.run_helper(FAKE_GO_CLOSE_TIMEOUT='1'), 0)
        self.assertIn('Go-to sheet still open', self.err)
        self.assertEqual(self.snapshot['keys'], KEYS[:2] + [['53']])
        self.assertTrue(self.snapshot['cancelled'])
        self.assertEqual(len(self.calls('sleep')), 20)
        self.assertRefused()

    def test_panel_close_timeout_fails_instead_of_reporting_success(self):
        self.assertNotEqual(self.run_helper(FAKE_PANEL_CLOSE_TIMEOUT='1'), 0)
        self.assertIn('panel still open after Open', self.err)
        self.assertEqual(self.snapshot['keys'], KEYS + [['53']])
        self.assertTrue(self.snapshot['cancelled'])
        self.assertEqual(len(self.calls('sleep')), 20)
        self.assertRefused()

    def test_each_failed_key_stops_the_sequence(self):
        for failing in range(1, 4):
            with self.subTest(failing=failing):
                self.assertNotEqual(self.run_helper(FAKE_KEY_FAIL=str(failing)), 0)
                self.assertIn('key', self.err)
                self.assertEqual(self.snapshot['keys'], KEYS[:failing])
                self.assertRefused()

    def test_awkward_target_roundtrip_is_exact_and_does_not_execute_content(self):
        for target in ('/tmp/a b/c d', '/tmp/跑01 图片/grid、fixtures', '/tmp/it\'s "quoted"/x',
                       '/tmp/$(touch pwned)/`id`/\\n back\\slash', '/tmp/trailing space ', '-n'):
            with self.subTest(target=target):
                self.assertEqual(self.run_helper(target), 0, self.err)
                self.assertEqual(self.snapshot['field'], target)
                self.assertEqual(self.snapshot['selected'], target)
                self.assertIn('chose: ' + target, self.out)
                self.assertFalse((self.repo / 'pwned').exists())

    def test_reports_input_source_read_only_before_selection(self):
        self.assertEqual(self.run_helper(FAKE_INPUT_SOURCE=PINYIN), 0, self.err)
        self.assertIn('input-source: ' + PINYIN, self.out.splitlines())
        self.assertEqual(self.snapshot['selected'], '/tmp/x')
        reads = [event for event in self.calls('osascript')
                 if 'TISCopyCurrentKeyboardInputSource' in event['script']]
        self.assertEqual(len(reads), 1)
        self.assertLess(self.log.index(reads[0]), self.log.index(self.calls('kc.sh')[0]))

    def test_input_source_read_failure_is_diagnostic_and_selection_continues(self):
        self.assertEqual(self.run_helper(FAKE_SOURCE_FAIL='1'), 0, self.err)
        self.assertTrue(any(line.startswith('input-source: unknown (') for line in self.out.splitlines()))
        self.assertEqual(self.snapshot['selected'], '/tmp/x')


if __name__ == '__main__':
    unittest.main()
