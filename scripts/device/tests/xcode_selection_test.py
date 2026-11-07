"""Offline Xcode selection tests using fake app bundles and xcodebuild tools."""
import os
from pathlib import Path
import stat
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import device as d


class XcodeSelection(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='mado-xcode-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def fake_xcode(self, name, build):
        app = self.root / name
        tool = app / 'Contents/Developer/usr/bin/xcodebuild'
        tool.parent.mkdir(parents=True)
        tool.write_text(f'#!/bin/sh\nprintf "Xcode 26.6\\nBuild version {build}\\n"\n')
        tool.chmod(tool.stat().st_mode | stat.S_IXUSR)
        return app

    def select(self, candidates, explicit=None):
        environment = {} if explicit is None else {'PICSEE_XCODE': str(explicit)}
        with patch.dict(os.environ, environment, clear=True):
            return d.select_xcode(candidates)

    def test_default_uses_first_candidate_with_locked_build(self):
        wrong = self.fake_xcode('Xcode-26.6.app', 'WRONG')
        valid = self.fake_xcode('Xcode.app', '17F113')
        selected, version = self.select((wrong, valid))
        self.assertEqual(selected, valid)
        self.assertIn('Build version 17F113', version)

    def test_default_prefers_first_matching_candidate(self):
        first = self.fake_xcode('Xcode-26.6.app', '17F113')
        second = self.fake_xcode('Xcode.app', '17F113')
        selected, _ = self.select((first, second))
        self.assertEqual(selected, first)

    def test_explicit_path_wins_and_is_checked(self):
        default = self.fake_xcode('Xcode-26.6.app', '17F113')
        explicit = self.fake_xcode('Custom.app', '17F113')
        selected, _ = self.select((default,), explicit)
        self.assertEqual(selected, explicit)

        invalid = self.fake_xcode('Invalid.app', 'WRONG')
        with self.assertRaisesRegex(RuntimeError, 'requires Xcode 26.6 build 17F113'):
            self.select((default,), invalid)

    def test_no_matching_candidate_uses_existing_error(self):
        wrong = self.fake_xcode('Xcode-26.6.app', 'WRONG')
        missing = self.root / 'Xcode.app'
        with self.assertRaisesRegex(RuntimeError, 'requires Xcode 26.6 build 17F113'):
            self.select((wrong, missing))


if __name__ == '__main__':
    unittest.main(verbosity=2)
