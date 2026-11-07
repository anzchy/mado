"""Offline entrypoint tests; every process replacement is fake, never a live kill."""
import contextlib
import io
import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch, Mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import device as d

class Regressions(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='picsee-offline-')
        self.addCleanup(self.temp.cleanup)
        self.run = Path(self.temp.name).resolve()
        self.app = self.run / 'Mado.app'
        self.exe = self.app / 'Contents/MacOS/Mado'
        self.record = dict(pid=4242, executable=str(self.exe), birth='Thu Oct 22 10:00:00 2026')
        (self.run / 'picsee.pid').write_text('4242')
        (self.run / 'bundle.path').write_text(str(self.app))
        (self.run / 'process.json').write_text(json.dumps(self.record))

    def test_pid_reuse_refuses_without_signaling(self):
        replacement = dict(self.record, birth='Thu Oct 22 10:01:00 2026')
        with patch.object(d, 'process_snapshot', return_value=replacement, create=True), patch.object(d, 'executable', return_value=self.exe), patch.object(d.time, 'sleep'), patch.object(d.os, 'kill') as kill:
            with self.assertRaisesRegex(RuntimeError, 'identity'):
                d.cleanup(self.run)
            kill.assert_not_called()
            self.assertTrue((self.run / 'retired').exists())

    def test_last_birth_check_before_signal(self):
        replacement = dict(self.record, birth='Thu Oct 22 10:01:00 2026')
        with patch.object(d, 'process_snapshot', side_effect=[self.record, replacement], create=True), patch.object(d, 'executable', return_value=self.exe), patch.object(d.time, 'sleep'), patch.object(d.os, 'kill') as kill:
            with self.assertRaisesRegex(RuntimeError, 'identity'):
                d.cleanup(self.run)
            kill.assert_not_called()

    def test_process_exit_between_path_and_birth_reads(self):
        with patch.object(d, 'executable', side_effect=[self.exe, None]), patch.object(d, 'checked', side_effect=RuntimeError('ps process exited')):
            self.assertIsNone(d.process_snapshot(4242))

    def test_process_exit_after_birth_read(self):
        with patch.object(d, 'executable', side_effect=[self.exe, None]), patch.object(d, 'checked', return_value=self.record['birth']):
            self.assertIsNone(d.process_snapshot(4242))

    def test_missing_ambiguous_and_retired_identity_refused(self):
        for mode in ['missing', 'ambiguous', 'retired']:
            with self.subTest(mode=mode):
                p = self.run / 'process.json'
                p.write_text(json.dumps(self.record))
                if mode == 'missing': p.unlink()
                if mode == 'ambiguous': p.write_text(json.dumps(dict(self.record, pid=4243)))
                if mode == 'retired': (self.run / 'retired').write_text('done')
                with patch.object(d, 'process_snapshot', return_value=self.record, create=True):
                    with self.assertRaises(RuntimeError): d.identity(self.run)
                if (self.run / 'retired').exists(): (self.run / 'retired').unlink()

    def test_identity_guards_input_and_capture_before_any_action(self):
        for filename, argv in [('input.py',['size',str(self.run),'800','600']),('screenshot.py',[str(self.run),'shot'])]:
            with self.subTest(filename=filename), patch.object(d, 'identity', side_effect=RuntimeError('process identity changed')), patch.object(d, 'checked') as checked:
                with patch.object(sys,'argv',[filename]+argv), contextlib.redirect_stdout(io.StringIO()):
                    with self.assertRaises(SystemExit) as result: runpy.run_path(str(d.HERE/filename),run_name='__main__')
                self.assertNotEqual(result.exception.code,0)
                checked.assert_not_called()

    def test_build_refuses_untracked_and_modified_inputs_allows_metadata(self):
        repo=self.run/'repo';repo.mkdir()
        def git(*args):return subprocess.check_output(['git','-C',str(repo),*args],text=True)
        git('init','-q');git('config','user.email','test@example.invalid');git('config','user.name','Test')
        (repo/'App').mkdir();(repo/'App/main.swift').write_text('committed')
        (repo/'project.yml').write_text('name: Test')
        git('add','App/main.swift','project.yml');git('commit','-qm','fixture')
        baseline=d.assert_clean_inputs(repo)
        for name in ['.codex/rules/a','.claude/state','docs/notes']:
            p=repo/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_text('agent metadata')
        self.assertEqual(d.assert_clean_inputs(repo),baseline)
        for name in ['App/new.swift','App/Info.plist','App/new.entitlements','App/Resources/icon.bin','UITests/test.swift','TestAssets/image.bin','Packages/P/Sources/a.swift']:
            p=repo/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_text('untracked')
            with self.assertRaises(RuntimeError):d.assert_clean_inputs(repo)
            with patch.object(d, 'ROOT', repo), patch.object(d, 'running', return_value=[]):
                with self.assertRaisesRegex(RuntimeError, 'untracked or missing build inputs'): d.build(self.run)
            p.unlink()
        (repo/'project.yml').write_text('modified')
        with self.assertRaises(RuntimeError):d.assert_clean_inputs(repo)

    def test_inventory_includes_non_swift_freshness(self):
        repo=self.run/'inputs';repo.mkdir();(repo/'App').mkdir()
        resource=repo/'App'/'Info.plist';resource.write_text('before')
        baseline=d.input_inventory(repo)
        resource.write_text('after')
        self.assertNotEqual(d.input_inventory(repo),baseline)

    def test_doctor_replaces_stale_pass_with_twelve_fail_closed_results(self):
        for failure in ['missing-bundle','missing-plist','malformed-record']:
            with self.subTest(failure=failure):
                if failure=='missing-plist': self.app.mkdir(exist_ok=True)
                if failure=='malformed-record': (self.run/'process.json').write_text('{broken')
                (self.run/'doctor.txt').write_text('PASS stale\n')
                with patch.object(sys,'argv',['device.py','doctor',str(self.run),'--expected-sha','abcdefg']), contextlib.redirect_stdout(io.StringIO()) as output:
                    result=d.main()
                lines=output.getvalue().strip().splitlines()
                self.assertEqual(result,1);self.assertEqual(len(lines),12)
                self.assertTrue(all(line.startswith(('PASS ','FAIL ')) for line in lines))
                self.assertEqual((self.run/'doctor.txt').read_text(),output.getvalue())
                self.assertNotIn('PASS stale',(self.run/'doctor.txt').read_text())

    def test_zero_and_untitled_windows_are_not_ax_errors(self):
        with patch.object(d,'checked',return_value='') as check:
            self.assertEqual(d.windows(4242),[])
            self.assertIn('every window',check.call_args.args[0][2])
            self.assertIn('missing value',check.call_args.args[0][2])
        with patch.object(d,'checked',return_value='\t960\t672'):
            self.assertEqual(d.windows(4242),[dict(title='',width='960',height='672')])

    def test_input_bad_argv_is_usage_not_traceback(self):
        r=subprocess.run([str(d.HERE/'size.sh')],text=True,capture_output=True)
        self.assertEqual(r.returncode,1)
        self.assertIn('usage:',r.stdout+r.stderr)
        self.assertNotIn('Traceback',r.stdout+r.stderr)

    def test_screenshot_entrypoint_denied_black_and_empty(self):
        for mode in ['denied','black','empty','visible']:
            with self.subTest(mode=mode):
                calls=[]
                def fake_checked(argv, **kwargs):
                    calls.append([str(a) for a in argv])
                    if any('winid.js' in str(a) for a in argv):return '99\t4242\t0\t960\t672\tPicsee'
                    if str(argv[0]).endswith('screencapture'):
                        Path(argv[-1]).write_bytes(b'' if mode=='empty' else b'fake PNG'+b'x'*200);return ''
                    if any('check-image.js' in str(a) for a in argv):
                        if mode=='black':raise RuntimeError('black or empty image')
                        return 'PASS image pixels'
                    return 'pixelWidth: 1920\npixelHeight: 1344'
                fakecg=Mock();fakecg.CGPreflightScreenCaptureAccess.return_value=mode!='denied'
                with patch.object(sys,'argv',['screenshot.py',str(self.run),mode]), patch.object(d,'identity',return_value=(4242,self.app)), patch.object(d,'executable',return_value=self.exe), patch.object(d,'checked',side_effect=fake_checked), patch('ctypes.CDLL',return_value=fakecg), contextlib.redirect_stdout(io.StringIO()):
                    try:runpy.run_path(str(d.HERE/'screenshot.py'),run_name='__main__');code=0
                    except SystemExit as e:code=1;message=str(e)
                self.assertEqual(code,0 if mode=='visible' else 1)
                if mode=='denied':
                    self.assertIn('Screen Recording',message)
                    self.assertFalse(any(a[0].endswith('screencapture') for a in calls))
                self.assertEqual((self.run/'shots'/f'{mode}.png').exists(),mode=='visible')
                self.assertFalse((self.run/'shots'/f'{mode}.capture.png').exists())

if __name__=='__main__':unittest.main(verbosity=2)
