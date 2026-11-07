"""Offline LaunchServices ownership regressions; no App is opened."""

import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import device as d

BIRTH = 'Tue Oct 27 12:00:01 2026'


class OpenHelper:
    def poll(self): return None
    def communicate(self): return ('', '')


class LaunchContractTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.run = Path(self.temp.name)
        self.app = (self.run / 'Mado.app').resolve()
        (self.run / 'bundle.path').write_text(str(self.app) + '\n')
        (self.run / 'build.json').write_text('{"sha":"abcdefg"}\n')
        self.record = dict(pid=4242, executable=str(self.app / 'Contents/MacOS/Mado'), birth=BIRTH)

    def launch_mocks(self, runs, snapshots):
        def fake_open(argv, **_):
            self.assertEqual(argv, ['/usr/bin/open', '-n', '-W', str(self.app)])
            return OpenHelper()
        return (patch.object(d, 'running', side_effect=runs),
                patch.object(d, 'process_snapshot', side_effect=snapshots),
                patch.object(d, 'checked', return_value='12345'),
                patch.object(d, 'windows', return_value=[{'title': 'Mado'}]),
                patch.object(d, 'logs', return_value='Mado launch git=abcdefg'),
                patch.object(d.subprocess, 'Popen', side_effect=fake_open))

    def test_records_new_launchservices_pid_executable_and_birth(self):
        mocks = self.launch_mocks([[], [4242]], [self.record, self.record])
        with patch.object(d, 'executable', return_value=Path(self.record['executable'])), \
                patch.object(d.time, 'time', return_value=1793073600.0):
            with mocks[0], mocks[1], mocks[2], mocks[3], mocks[4], mocks[5]:
                d.launch(self.run)
        self.assertEqual(json.loads((self.run / 'process.json').read_text()), self.record)
        self.assertEqual((self.run / 'picsee.pid').read_text(), '4242\n')

    def test_preexisting_same_bundle_is_never_recorded_or_stopped(self):
        with patch.object(d, 'running', return_value=[3000]), \
                patch.object(d.subprocess, 'Popen') as opened, patch.object(d.os, 'kill') as kill, \
                patch.object(d.time, 'sleep', side_effect=AssertionError('must not wait')):
            with self.assertRaisesRegex(RuntimeError, 'another Mado'):
                d.launch(self.run)
        self.assertFalse((self.run / 'process.json').exists())
        opened.assert_not_called()
        kill.assert_not_called()

    def test_timeout_after_record_preserves_ownership_for_cleanup(self):
        with patch.object(d, 'running', side_effect=[[], [4242]]), \
                patch.object(d, 'process_snapshot', return_value=self.record), \
                patch.object(d, 'executable', return_value=Path(self.record['executable'])), \
                patch.object(d, 'checked', return_value=''), \
                patch.object(d, 'windows', return_value=[]), \
                patch.object(d, 'logs', return_value=''), \
                patch.object(d.time, 'time', return_value=1793073600.0), \
                patch.object(d.time, 'monotonic', side_effect=[0, 1, 31]), \
                patch.object(d.time, 'sleep'), patch.object(d.os, 'kill') as kill, \
                patch.object(d.subprocess, 'Popen', return_value=OpenHelper()):
            with self.assertRaisesRegex(RuntimeError, 'ready timeout'):
                d.launch(self.run)
        self.assertEqual(json.loads((self.run / 'process.json').read_text()), self.record)
        kill.assert_not_called()

    def test_observed_process_exits_before_identity_record_without_30_second_wait(self):
        with patch.object(d, 'running', side_effect=[[], [4242]]), \
                patch.object(d, 'process_snapshot', return_value=None), \
                patch.object(d, 'executable', return_value=Path(self.record['executable'])), \
                patch.object(d, 'checked', return_value=''), \
                patch.object(d.time, 'time', return_value=1793073600.0), \
                patch.object(d.time, 'monotonic', side_effect=[0, 1]), \
                patch.object(d.time, 'sleep') as sleep, \
                patch.object(d.subprocess, 'Popen', return_value=OpenHelper()):
            with self.assertRaisesRegex(RuntimeError, 'disappeared|exited'):
                d.launch(self.run)
        sleep.assert_not_called()

    def test_multiple_new_matching_processes_are_never_recorded(self):
        with patch.object(d, 'running', side_effect=[[], [4242, 4243]]), \
                patch.object(d, 'executable', return_value=Path(self.record['executable'])), \
                patch.object(d, 'checked', return_value=''), \
                patch.object(d.subprocess, 'Popen', return_value=OpenHelper()), \
                patch.object(d.time, 'monotonic', side_effect=[0, 1]), \
                patch.object(d.time, 'sleep') as sleep, patch.object(d.os, 'kill') as kill:
            with self.assertRaisesRegex(RuntimeError, 'more than one'):
                d.launch(self.run)
        self.assertFalse((self.run / 'process.json').exists())
        sleep.assert_not_called()
        kill.assert_not_called()

    def test_old_birth_cannot_be_recorded_even_for_new_pid(self):
        old = dict(self.record, birth='Tue Oct 27 11:59:59 2026')
        with patch.object(d, 'running', side_effect=[[], [4242]]), \
                patch.object(d, 'process_snapshot', return_value=old), \
                patch.object(d, 'executable', return_value=Path(self.record['executable'])), \
                patch.object(d, 'checked', return_value=''), \
                patch.object(d.subprocess, 'Popen', return_value=OpenHelper()), \
                patch.object(d.time, 'time', return_value=1793073600.0), \
                patch.object(d.time, 'monotonic', side_effect=[0, 1]), \
                patch.object(d.os, 'kill') as kill:
            with self.assertRaisesRegex(RuntimeError, 'birth'):
                d.launch(self.run)
        self.assertFalse((self.run / 'process.json').exists())
        kill.assert_not_called()

    def test_launchservices_reports_immediate_exit_before_pid_observation(self):
        class OpenHelper:
            def poll(self): return 0
            def communicate(self): return ('', '')
        with patch.object(d, 'running', side_effect=[[], []]), \
                patch.object(d, 'checked', return_value=''), \
                patch.object(d.subprocess, 'Popen', return_value=OpenHelper()), \
                patch.object(d.time, 'monotonic', side_effect=[0, 1, 31]), \
                patch.object(d.time, 'sleep'):
            with self.assertRaisesRegex(RuntimeError, 'exited'):
                d.launch(self.run)
        self.assertFalse((self.run / 'process.json').exists())

    def test_app_lang_file_passes_apple_languages_for_this_launch_only(self):
        (self.run / 'app-lang.txt').write_text('zh-Hans\n')
        seen = []
        def fake_open(argv, **_):
            seen.append(argv)
            return OpenHelper()
        with patch.object(d, 'running', side_effect=[[], [4242]]), \
                patch.object(d, 'process_snapshot', return_value=self.record), \
                patch.object(d, 'executable', return_value=Path(self.record['executable'])), \
                patch.object(d, 'checked', return_value='12345'), \
                patch.object(d, 'windows', return_value=[{'title': 'Mado'}]), \
                patch.object(d, 'logs', return_value='Mado launch git=abcdefg'), \
                patch.object(d.subprocess, 'Popen', side_effect=fake_open), \
                patch.object(d.time, 'time', return_value=1793073600.0):
            d.launch(self.run)
        self.assertEqual(seen, [['/usr/bin/open', '-n', '-W', str(self.app),
                                 '--args', '-AppleLanguages', '(zh-Hans)']])

    def test_app_lang_file_rejects_values_that_are_not_a_language_tag(self):
        (self.run / 'app-lang.txt').write_text('zh-Hans) -NSFoo (x\n')
        with patch.object(d, 'running', return_value=[]), \
                patch.object(d.subprocess, 'Popen') as opened:
            with self.assertRaisesRegex(RuntimeError, 'app-lang'):
                d.launch(self.run)
        opened.assert_not_called()
        self.assertFalse((self.run / 'process.json').exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)
