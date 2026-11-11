#!/usr/bin/env python3
"""Offline acceptance/failure probes for the #637 WindowServer result parser."""
import importlib.util
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zlib

RUNNER = Path(__file__).with_name('issue637-desktop.py')
spec = importlib.util.spec_from_file_location('issue637_desktop', RUNNER)
desktop = importlib.util.module_from_spec(spec)
spec.loader.exec_module(desktop)


def synthetic_png(path, grey, marks):
    rows = []
    for y in range(640):
        row = bytearray()
        for x in range(960):
            row.extend(marks.get((x, y), (grey, grey, grey)))
        rows.append(b'\0' + row)
    path.write_bytes(b'\x89PNG\r\n\x1a\n' + desktop.chunk(b'IHDR',
        struct.pack('>IIBBBBB', 960, 640, 8, 2, 0, 0, 0)) + desktop.chunk(b'sRGB', b'\0') +
        desktop.chunk(b'IDAT', zlib.compress(b''.join(rows), 9)) + desktop.chunk(b'IEND', b''))


def build_manifest(folder, *, base=False, missing=False, wrong_image=False, unstable=False):
    captures = {}
    points = ((36, 592), (480, 592), (790, 592))
    for page in desktop.PAGES:
        for theme in desktop.THEMES:
            panel = (255, 255, 255) if theme == 'light' else (20, 24, 33)
            for grey in desktop.GREYS:
                for opacity in desktop.TIERS:
                    if missing and (page, theme, grey, opacity) == ('16', 'dark', 226, 50):
                        continue
                    coverage = 1 if opacity == 100 else .5 + .5 * opacity / 100
                    if base and opacity == 30:
                        coverage = .96
                    color = tuple(round(grey + (p - grey) * coverage) for p in panel)
                    marks = {point: color for point in points}
                    if wrong_image and (page, theme, grey, opacity) == ('14', 'light', 69, 30):
                        marks[(250, 632)] = (80, 80, 80)
                    if unstable and (page, theme, grey, opacity) == ('14', 'dark', 69, 100):
                        marks.update({point: (69, 69, 69) for point in points})
                    key = f'{page}-{theme}-{grey}-{opacity}'
                    path = folder / f'{key}.png'
                    synthetic_png(path, grey, marks)
                    captures[key] = str(path)
    for key in ('pattern-light-30', 'pattern-light-100', 'pattern-light-zoom'):
        marks = {}
        for y in (592, 632):
            for x in range(16, 820):
                value = 0 if x // 4 % 2 else 255
                if y == 592 and key == 'pattern-light-30':
                    value = 128
                if y == 320 and key == 'pattern-light-zoom':
                    value = 255 - value
                marks[(x, y)] = (value, value, value)
        if key == 'pattern-light-zoom':
            for x in range(100, 860, 8):
                marks[(x, 320)] = (0, 0, 0)
        elif key == 'pattern-light-100':
            for x in range(100, 860, 8):
                marks[(x, 320)] = (255, 255, 255)
        path = folder / f'{key}.png'
        synthetic_png(path, 128, marks)
        captures[key] = str(path)
    replacement = folder / 'replacement-light-69.png'
    synthetic_png(replacement, 69, {})
    captures['replacement-light-69'] = str(replacement)
    for key in ('active-light-69', 'inactive-light-69', 'hidden-light-69', 'wake-light-69'):
        path = folder / f'{key}.png'
        marks = {point: (190, 190, 190) for point in points} if key == 'wake-light-69' else {}
        synthetic_png(path, 69, marks)
        captures[key] = str(path)
    manifest = folder / 'capture-manifest.json'
    manifest.write_text(json.dumps(dict(captures=captures, source='synthetic', build={'sha': 'fixture'})))
    return manifest


class DesktopParserTests(unittest.TestCase):
    def test_complete_candidate_passes_and_reports_matrix(self):
        with tempfile.TemporaryDirectory() as temp:
            manifest = build_manifest(Path(temp))
            verdict = desktop.analyze(manifest)
            self.assertEqual(verdict['status'], 'PASS')
            self.assertEqual(verdict['sampleCount'], 72)
            self.assertEqual(len(verdict['smoothing']), 3)
            self.assertTrue(any('page 33' in item for item in verdict['notVerified']))
            omitted = [row for row in verdict['samples'] if row['omitted']]
            self.assertEqual(len(omitted), 18)  # light/grey226, 2 pages × 3 tiers × 3 groups

    def test_known_solid_base_fails_30_percent_cells(self):
        with tempfile.TemporaryDirectory() as temp:
            verdict = desktop.analyze(build_manifest(Path(temp), base=True))
            self.assertEqual(verdict['status'], 'FAIL')
            self.assertTrue(any('30/left' in reason for reason in verdict['failures']))

    def test_incomplete_and_wrong_frame_are_environment_results(self):
        for defect in ('missing', 'wrong_image'):
            with self.subTest(defect=defect), tempfile.TemporaryDirectory() as temp:
                folder = Path(temp)
                manifest = build_manifest(folder, **{defect: True})
                verdict = folder / 'verdict.json'
                result = subprocess.run([sys.executable, RUNNER, 'analyze', '--manifest', manifest,
                    '--out', verdict], capture_output=True, text=True)
                self.assertEqual(result.returncode, 70)
                self.assertEqual(json.loads(verdict.read_text())['status'], 'ENVIRONMENT')

    def test_unstable_only_nonexempt_cell_is_failure(self):
        with tempfile.TemporaryDirectory() as temp:
            verdict = desktop.analyze(build_manifest(Path(temp), unstable=True))
            self.assertEqual(verdict['status'], 'FAIL')
            self.assertTrue(any('unstable' in reason for reason in verdict['failures']))

    def test_settings_window_is_checked_before_sidebar_identifier(self):
        calls = []
        def fake_ax(_pid, operation, identifier):
            calls.append((operation, identifier))
            if operation == 'settings-window':
                return 'PASS settings-window Display'
            raise desktop.EnvironmentFailure('AXIdentifier not found in Settings window')
        with patch.object(desktop, 'key'), patch.object(desktop, 'ax', side_effect=fake_ax):
            with self.assertRaisesRegex(desktop.EnvironmentFailure, 'Settings sidebar lookup failed'):
                desktop.settings(Path('/unused'), Path('/unused'), 123)
        self.assertEqual(calls, [('settings-window', 'window'), ('value', 'settings.section.general')])

    def test_ax_timeout_names_identifier_window_list_and_elapsed(self):
        timeout = subprocess.TimeoutExpired(['/usr/bin/osascript'], 12)
        with patch.object(desktop, 'invoke', side_effect=[timeout, 'Display 760x514; Mado 960x640;']) as invoker:
            with self.assertRaises(desktop.EnvironmentFailure) as caught:
                desktop.ax(123, 'value', 'settings.display.tool-opacity')
        self.assertEqual(invoker.call_args_list[0].args[0][1:3], ['-l', 'JavaScript'])
        self.assertEqual(Path(invoker.call_args_list[0].args[0][3]).name, 'issue637-ax.js')
        message = str(caught.exception)
        self.assertIn('identifier=settings.display.tool-opacity', message)
        self.assertIn('windows=[Display 760x514; Mado 960x640;]', message)
        self.assertRegex(message, r'elapsed=\d+\.\d+s')

    def test_dry_ax_cli_routes_to_short_ax_path_and_writes_verdict(self):
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / 'dry-ax'
            result = dict(status='PASS', scope='Settings AX only', sampleCount=0,
                          samples=[], failures=[], notVerified=['desktop pixel matrix was not run'])
            with patch.object(desktop, 'capture', return_value=result) as capture, \
                 patch.object(sys, 'argv', ['issue637-desktop.py', 'dry-ax',
                                           '--source', str(Path(temp) / 'base'), '--out', str(output)]):
                self.assertEqual(desktop.main(), 0)
            self.assertTrue(capture.call_args.kwargs['dry_ax'])
            self.assertEqual(json.loads((output / 'verdict.json').read_text())['status'], 'PASS')


if __name__ == '__main__':
    unittest.main()
