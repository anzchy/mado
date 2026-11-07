"""Round-two offline tests: report storage failures, re-signing, launch evidence."""
import contextlib
import errno
import hashlib
import io
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import device as d

class RoundTwo(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='mado-fix2-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve() / 'repo'
        self.root.mkdir()
        self.run = self.root.parent / 'run'
        self.run.mkdir()

    def test_enospc_prints_all_verdicts_before_write_and_retires_old_report(self):
        data = dict(expectedSHA='abcdefg', sha='abcdefg', bundleID='io.github.anzchy.mado',
                    team='GRT84NAK4T', signatureValid=True, sandbox=True, processMatches=True,
                    fresh=True, alone=True, windows=[dict(title='Mado')],
                    log='Mado launch git=abcdefg', machineMatches=True, fixturesIntact=True)
        old = self.run / 'doctor.txt'
        old.write_text('PASS stale previous report\n')
        observed_line_counts = []
        with contextlib.redirect_stdout(io.StringIO()) as output:
            def fail_write(path, value):
                observed_line_counts.append(len(output.getvalue().splitlines()))
                raise OSError(errno.ENOSPC, 'No space left on device')
            with patch.object(d, 'collect', return_value=data), patch.object(d, 'atomic_text', side_effect=fail_write), patch.object(sys, 'argv', ['device.py','doctor',str(self.run),'--expected-sha','abcdefg']):
                result = d.main()
        lines = output.getvalue().splitlines()
        self.assertEqual(result, 1)
        expected = ['PASS ' + check for check in d.CHECKS]
        expected[d.CHECKS.index('window')] = 'PASS window — title=Mado'
        self.assertEqual(lines[:12], expected)
        self.assertEqual(len(lines), 13)
        self.assertEqual(observed_line_counts, [12])
        self.assertTrue(lines[12].startswith('FAIL report-write — '))
        self.assertIn('No space left', lines[12])
        self.assertFalse(old.exists())
        self.assertEqual((self.run/'doctor.stale.txt').read_text(), 'PASS stale previous report\n')

    def test_post_build_resign_success_failure_and_clean_stamp(self):
        for mode in ('dirty-success', 'dirty-failure', 'clean'):
            with self.subTest(mode=mode):
                run = self.run / mode
                run.mkdir()
                app = self.root / '.build' / ('device-' + run.name) / 'Build/Products/Debug/Mado.app'
                plist = app / 'Contents/Info.plist'
                calls = []
                def fake_build(argv, **kwargs):
                    if str(argv[0]).endswith('xcodebuild'):
                        plist.parent.mkdir(parents=True)
                        plist.write_bytes(plistlib.dumps(dict(MadoGitSHA='abcdefg' if mode=='clean' else 'abcdefg-dirty')))
                    return subprocess.CompletedProcess(argv,0)
                def fake_checked(argv, **kwargs):
                    argv = [str(a) for a in argv]
                    calls.append(argv)
                    if argv[0].endswith('xcodebuild'): return 'Xcode 26.6\nBuild version 17F113'
                    if argv[0]=='git': return 'abcdefg' if '--short' in argv else 'abcdefg-full'
                    if argv[0].endswith('PlistBuddy'):
                        plist.write_bytes(plistlib.dumps(dict(MadoGitSHA='abcdefg')))
                        return ''
                    if argv[0].endswith('codesign') and argv[1]=='-d':
                        # The leaf certificate xcodebuild signed with; a second same-named identity must not matter.
                        prefix = argv[2].split('=',1)[1]
                        Path(prefix+'0').write_bytes(b'fake-leaf-der')
                        Path(prefix+'1').write_bytes(b'fake-intermediate-der')
                        return ''
                    if argv[0].endswith('codesign'):
                        if mode=='dirty-failure': raise RuntimeError('fake re-sign failed')
                        return ''
                    raise AssertionError(argv)
                with patch.object(d,'ROOT',self.root), patch.object(d,'running',return_value=[]), patch.object(d,'assert_clean_inputs',return_value={'App/main.swift':'hash'}), patch.object(d,'checked',side_effect=fake_checked), patch.object(d.subprocess,'run',side_effect=fake_build), patch.object(d,'machine',return_value={'scale':2}), patch.object(sys,'argv',['device.py','build',str(run)]), patch.dict(d.os.environ,{},clear=False), contextlib.redirect_stdout(io.StringIO()) as output:
                    result = d.main()
                signing = [a for a in calls if a[0].endswith('codesign') and '--sign' in a]
                stamping = [a for a in calls if a[0].endswith('PlistBuddy')]
                expected_count = 0 if mode=='clean' else 1
                self.assertEqual(len(stamping), expected_count)
                self.assertEqual(len(signing), expected_count)
                if expected_count:
                    self.assertEqual(stamping[0], ['/usr/libexec/PlistBuddy','-c','Set :MadoGitSHA abcdefg',str(plist)])
                    self.assertEqual(signing[0], ['/usr/bin/codesign','--force','--sign',hashlib.sha1(b'fake-leaf-der').hexdigest().upper(),'--preserve-metadata=entitlements,requirements,flags,runtime',str(app)])
                if mode=='dirty-failure':
                    self.assertEqual(result, 1)
                    self.assertIn('FAIL build — fake re-sign failed',output.getvalue())
                    self.assertFalse((run/'build.json').exists())
                    self.assertFalse((run/'bundle.path').exists())
                else:
                    self.assertEqual(result, 0, output.getvalue())
                    self.assertEqual(json.loads((run/'build.json').read_text())['sha'],'abcdefg')
                    self.assertEqual(plistlib.loads(plist.read_bytes())['MadoGitSHA'],'abcdefg')

    def test_launch_preserves_original_start_on_reused_run(self):
        (self.run/'start.txt').write_text('original timestamp')
        (self.run/'retired').write_text('retired')
        (self.run/'bundle.path').write_text(str(self.root/'Mado.app'))
        (self.run/'build.json').write_text('{"sha":"abcdefg"}')
        with patch.object(d,'running',return_value=[]), patch.object(d,'checked') as checked:
            with self.assertRaisesRegex(RuntimeError, 'ownership record'):
                d.launch(self.run)
            checked.assert_not_called()
        self.assertEqual((self.run/'start.txt').read_text(),'original timestamp')

if __name__=='__main__': unittest.main(verbosity=2)
