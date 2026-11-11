#!/usr/bin/env python3
"""#637 device-only Release backdrop measurement; outputs stay outside the repo.

Run from a Screen Recording/Accessibility-authorized Terminal.app after the
delegator acquires the shared desktop GUI lock. The command is noninteractive.
It refuses a pre-existing Mado and only terminates the exact process it starts.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(ROOT / 'scripts' / 'device'))
import device  # noqa: E402 - reuse the device lane's PID/bundle identity checks


def checked(argv, timeout=30):
    result = subprocess.run([str(value) for value in argv], capture_output=True, text=True,
                            timeout=timeout, env={**os.environ, 'LC_ALL': 'C'})
    if result.returncode:
        raise RuntimeError(f'{argv[0]} failed ({result.returncode}): '
                           + (result.stderr.strip() or result.stdout.strip()))
    return result.stdout.strip()


def verify_gui_lock(run_id, acquisition_id):
    owner = Path.home() / '.cache' / 'desktop-gui.lock' / 'owner'
    if owner.is_symlink() or not owner.is_file():
        raise RuntimeError('shared desktop GUI lock is absent or invalid')
    values = dict(line.split('=', 1) for line in owner.read_text().splitlines() if '=' in line)
    if values.get('project') != 'picsee' or values.get('batch') != run_id \
            or values.get('acquisition_id') != acquisition_id:
        raise RuntimeError('shared desktop GUI lock belongs to another acquisition')


def verify_app(app):
    if app.name != 'Mado.app' or app.parent.name != 'Release':
        raise RuntimeError('expected a signed Build/Products/Release/Mado.app')
    info = plistlib.loads((app / 'Contents' / 'Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != 'io.github.anzchy.mado':
        raise RuntimeError('wrong bundle identifier')
    sha = info.get('MadoGitSHA')
    if not isinstance(sha, str) or not re.fullmatch(r'[0-9a-f]{7,40}', sha):
        raise RuntimeError('missing MadoGitSHA build stamp')
    checked(['/usr/bin/codesign', '--verify', '--deep', '--strict', app])
    signature = subprocess.run(['/usr/bin/codesign', '-dv', '--verbose=2', str(app)],
                               capture_output=True, text=True, check=True).stderr
    if 'TeamIdentifier=GRT84NAK4T' not in signature:
        raise RuntimeError('unexpected signing team')
    entitlements = checked(['/usr/bin/codesign', '-d', '--entitlements', ':-', app])
    if not device.sandbox_enabled(entitlements):
        raise RuntimeError('App Sandbox entitlement absent')
    return sha


def verify_image(image):
    if not image.is_file() or not image.is_relative_to(Path.home() / '.picsee' / 'testassets' / 'generated' / 'S3'):
        raise RuntimeError('image must be an existing generated S3 TestAssets image')
    details = checked(['/usr/bin/sips', '-g', 'pixelWidth', '-g', 'pixelHeight', image])
    width = int(re.search(r'pixelWidth:\s*(\d+)', details).group(1))
    height = int(re.search(r'pixelHeight:\s*(\d+)', details).group(1))
    if width * height < 48_000_000:
        raise RuntimeError('image must be at least 48 megapixels')
    digest = hashlib.sha256()
    with image.open('rb') as stream:
        for block in iter(lambda: stream.read(1 << 20), b''):
            digest.update(block)
    return {'width': width, 'height': height, 'bytes': image.stat().st_size,
            'sha256': digest.hexdigest(), 'path': str(image)}


def window_geometry(pid, index=1):
    script = '''on run argv
      tell application "System Events" to tell (first process whose unix id is (item 1 of argv as integer))
        set frontmost to true
        set w to window (item 2 of argv as integer)
        perform action "AXRaise" of w
        set p to position of w
        set s to size of w
        return (item 1 of p as text) & tab & (item 2 of p as text) & tab & (item 1 of s as text) & tab & (item 2 of s as text)
      end tell
    end run'''
    values = checked(['/usr/bin/osascript', '-e', script, pid, index], timeout=10).split('\t')
    if len(values) != 4:
        raise RuntimeError('Accessibility did not return a window rectangle')
    rect = [int(value) for value in values]
    if rect[2] < 500 or rect[3] < 350:
        raise RuntimeError('window is too small for controlled pan/zoom')
    return rect


def rss_sample(pid):
    output = checked(['/bin/ps', '-o', 'rss=', '-p', pid])
    return {'us': time.time_ns() // 1000, 'rssBytes': int(output) * 1024}


def launch(app, image):
    if device.running():
        raise RuntimeError('another Mado is running; ask its owner to quit it')
    checked(['/usr/bin/open', '-n', '-a', app, image], timeout=30)
    deadline = time.monotonic() + 30
    executable = app / 'Contents' / 'MacOS' / 'Mado'
    while time.monotonic() < deadline:
        candidates = [pid for pid in device.running() if device.executable(pid) == executable]
        if len(candidates) == 1:
            record = device.process_snapshot(candidates[0])
            if record:
                return record
        elif len(candidates) > 1:
            raise RuntimeError('multiple new Mado processes; identity ambiguous')
        time.sleep(0.2)
    raise RuntimeError('Mado did not open a visible window within 30 seconds')


def drive(pid, index, iterations, rss):
    rect = window_geometry(pid, index)
    argv = ['/usr/bin/osascript', '-l', 'JavaScript', HERE / 'issue637-drive.js',
            pid, *rect, iterations]
    child = subprocess.Popen([str(arg) for arg in argv], stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, text=True)
    deadline = time.monotonic() + 180
    try:
        while child.poll() is None:
            if time.monotonic() >= deadline:
                raise RuntimeError('CGEvent driver exceeded 180 seconds')
            rss.append(rss_sample(pid))
            time.sleep(0.1)
    finally:
        if child.poll() is None:
            child.terminate()
            child.wait(timeout=5)
    stdout, stderr = child.communicate()
    if child.returncode or f'sent={iterations}' not in stdout:
        raise RuntimeError('Accessibility/CGEvent driver failed: ' + (stderr.strip() or stdout.strip()))
    return {'windowIndex': index, 'iterations': iterations, 'geometry': rect,
            'driver': stdout.strip()}


def collect_log(pid, start):
    return checked(['/usr/bin/log', 'show', '--signpost', '--info', '--style', 'ndjson',
        '--start', start, '--predicate',
        f'subsystem == "io.github.anzchy.mado" AND category == "chrome-backdrop" AND processID == {pid}'],
        timeout=180)


def vmmap_snapshot(pid, out, name):
    """Save raw allocator-region evidence; no allocation count is inferred from RSS."""
    try:
        result = subprocess.run(['/usr/bin/vmmap', '-summary', str(pid)], capture_output=True,
                                text=True, timeout=60)
        (out / f'vmmap-{name}.txt').write_text(result.stdout + result.stderr)
        return 'available' if result.returncode == 0 else 'unknown (vmmap exit ' + str(result.returncode) + ')'
    except Exception as error:
        (out / f'vmmap-{name}.txt').write_text('unavailable: ' + str(error) + '\n')
        return 'unknown (' + str(error) + ')'


def retire_owned(record):
    if record is None:
        return
    current = device.process_snapshot(record['pid'])
    if current is None:
        return
    if current != record or device.process_snapshot(record['pid']) != record:
        raise RuntimeError('Mado process identity changed; refusing to signal')
    os.kill(record['pid'], signal.SIGTERM)
    for _ in range(50):
        if device.process_snapshot(record['pid']) != record:
            return
        time.sleep(0.1)
    raise RuntimeError('owned Mado remained alive 5 seconds after SIGTERM; keep the GUI lock')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', required=True, type=Path)
    parser.add_argument('--image', required=True, type=Path)
    parser.add_argument('--out', required=True, type=Path)
    parser.add_argument('--run-id', required=True)
    parser.add_argument('--gui-acquisition-id', required=True)
    parser.add_argument('--iterations', type=int, default=40)
    options = parser.parse_args()
    record = None
    try:
        if options.iterations < 30:
            raise RuntimeError('at least 30 controlled interactions are required')
        app, image, out = options.app.resolve(), options.image.resolve(), options.out.resolve()
        if out == ROOT or out.is_relative_to(ROOT) or out.exists():
            raise RuntimeError('output must be a new directory outside the worktree')
        verify_gui_lock(options.run_id, options.gui_acquisition_id)
        sha = verify_app(app)
        image_meta = verify_image(image)
        out.mkdir(parents=True)
        start = datetime.datetime.now().astimezone().strftime('%Y-%m-%d %H:%M:%S')
        record = launch(app, image)
        pid = record['pid']
        ready = time.monotonic() + 30
        while time.monotonic() < ready and not any(
                window['title'] == image.name for window in device.windows(pid)):
            time.sleep(0.2)
        if not any(window['title'] == image.name for window in device.windows(pid)):
            raise RuntimeError('Mado did not open a window titled with the requested image within 30 seconds')
        rss = [rss_sample(pid)]
        vmmap_before = vmmap_snapshot(pid, out, 'before')
        runs = [drive(pid, 1, options.iterations, rss)]
        time.sleep(2)
        rss.append(rss_sample(pid))
        vmmap_after = vmmap_snapshot(pid, out, 'after')
        (out / 'rss.ndjson').write_text(''.join(json.dumps(row) + '\n' for row in rss))
        (out / 'signposts.ndjson').write_text(collect_log(pid, start) + '\n')
        meta = {'buildSHA': sha, 'configuration': 'Release (bundle in Build/Products/Release)',
                'signedTeam': 'GRT84NAK4T', 'sandbox': True, 'app': str(app),
                'machine': device.machine(), 'image': image_meta,
                'windowsMeasured': len(runs), 'drives': runs, 'pid': pid, 'start': start,
                'multipleWindowCost': 'unknown — current viewer is single-window (P4-01)',
                'vmmapBefore': vmmap_before, 'vmmapAfter': vmmap_after,
                'inputToStateFeedback': 'unknown — not instrumented by this run'}
        (out / 'meta.json').write_text(json.dumps(meta, indent=2) + '\n')
        result = subprocess.run(['node', str(HERE / 'issue637-parse.mjs'),
            '--log', str(out / 'signposts.ndjson'), '--rss', str(out / 'rss.ndjson'),
            '--meta', str(out / 'meta.json'), '--out', str(out / 'report.json')],
            capture_output=True, text=True)
        print(result.stdout or result.stderr, end='')
        return result.returncode
    except Exception as error:
        print(f'INCONCLUSIVE issue637 perf: {error}', file=sys.stderr)
        return 1
    finally:
        if record is not None:
            try:
                retire_owned(record)
            except Exception as error:
                raise RuntimeError(f'owned Mado cleanup failed: {error}') from error


if __name__ == '__main__':
    sys.exit(main())
