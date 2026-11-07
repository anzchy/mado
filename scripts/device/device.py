#!/usr/bin/env python3
"""Local device-run orchestration. Evidence stays outside the checkout."""
import argparse
import ctypes
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
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
LOCKED_XCODE_BUILD = 'Build version 17F113'
DEFAULT_XCODE_APPS = (Path('/Applications/Xcode-26.6.app'), Path('/Applications/Xcode.app'))

def command(argv, timeout=30):
    return subprocess.run([str(a) for a in argv], text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, timeout=timeout, env={**os.environ, 'LC_ALL': 'C'})

def checked(argv, timeout=30, strip=True):
    r = command(argv, timeout)
    if r.returncode:
        raise RuntimeError(r.stderr.strip() or r.stdout.strip() or str(argv))
    return r.stdout.strip() if strip else r.stdout

def select_xcode(candidates=DEFAULT_XCODE_APPS):
    explicit = os.environ.get('PICSEE_XCODE')
    choices = (Path(explicit),) if explicit else tuple(Path(path) for path in candidates)
    for app in choices:
        try:
            version = checked([app / 'Contents/Developer/usr/bin/xcodebuild', '-version'])
        except (OSError, RuntimeError, subprocess.TimeoutExpired):
            continue
        if LOCKED_XCODE_BUILD in version:
            return app, version
    raise RuntimeError('requires Xcode 26.6 build 17F113')

def executable(pid):
    lib = ctypes.CDLL('/usr/lib/libproc.dylib')
    buf = ctypes.create_string_buffer(4096)
    if lib.proc_pidpath(int(pid), buf, len(buf)) <= 0:
        return None
    return Path(os.fsdecode(buf.value)).resolve()

def process_snapshot(pid):
    before = executable(pid)
    if before is None:
        return None
    try:
        birth = checked(['/bin/ps', '-o', 'lstart=', '-p', str(pid)])
    except RuntimeError:
        if executable(pid) is None:
            return None  # The process exited between path and birth reads.
        raise
    datetime.datetime.strptime(birth, '%a %b %d %H:%M:%S %Y')
    after = executable(pid)
    if after is None:
        return None
    if after != before:
        raise RuntimeError('process identity changed while reading birth time')
    return dict(pid=pid, executable=str(before), birth=birth)

def recorded_identity(run):
    if (run / 'retired').exists():
        raise RuntimeError('process identity record is retired')
    try:
        pid = int((run / 'picsee.pid').read_text().strip())
        app = Path((run / 'bundle.path').read_text().strip()).resolve()
        record = json.loads((run / 'process.json').read_text())
        if (pid <= 1 or type(record['pid']) is not int or record['pid'] != pid
                or not record['birth'] or not isinstance(record['birth'], str)
                or not Path(record['executable']).is_absolute()):
            raise ValueError('ambiguous PID, executable or birth')
        datetime.datetime.strptime(record['birth'], '%a %b %d %H:%M:%S %Y')
        if not inside(Path(record['executable']).resolve(), app):
            raise ValueError('executable outside recorded bundle')
    except Exception as e:
        raise RuntimeError('invalid process identity record: ' + str(e)) from e
    return pid, app, record

def identity(run):
    pid, app, record = recorded_identity(run)
    if process_snapshot(pid) != record:
        raise RuntimeError('process identity differs from recorded birth, PID or executable')
    return pid, app

def inside(exe, app):
    return exe is not None and exe.is_relative_to(app / 'Contents' / 'MacOS')

def running():
    try:
        r = command(['/usr/bin/pgrep', '-x', 'Mado'])
    except (OSError, subprocess.TimeoutExpired) as error:
        raise RuntimeError('pgrep process query failed: ' + str(error)) from error
    if r.returncode == 1 and not r.stdout.strip() and not r.stderr.strip():
        return []
    if r.returncode != 0:
        raise RuntimeError(f'pgrep process query failed (exit {r.returncode}): '
                           + (r.stderr.strip() or r.stdout.strip() or 'inconsistent result'))
    if r.stderr.strip():
        raise RuntimeError('pgrep process query emitted a diagnostic: ' + r.stderr.strip())
    parts = r.stdout.split()
    if not parts or any(not re.fullmatch(r'[0-9]+', part) for part in parts):
        raise RuntimeError('pgrep returned malformed or empty PID list')
    pids = [int(part) for part in parts]
    if any(pid <= 1 for pid in pids) or len(set(pids)) != len(pids):
        raise RuntimeError('pgrep returned malformed or duplicate PID list')
    return pids

def windows(pid):
    script = '''on run argv
    set targetPID to item 1 of argv as integer
    tell application "System Events"
      tell (first process whose unix id is targetPID)
        set windowSnapshot to properties of every window
      end tell
      set resultText to ""
      repeat with w in windowSnapshot
        set titleText to name of w
        if titleText is missing value then set titleText to ""
        set dimensions to size of w
        set resultText to resultText & titleText & tab & (item 1 of dimensions) & tab & (item 2 of dimensions) & linefeed
      end repeat
      return resultText
    end tell
    end run'''
    output = checked(['/usr/bin/osascript', '-e', script, str(pid)], timeout=5, strip=False).rstrip('\r\n')
    return [dict(zip(['title', 'width', 'height'], line.split('\t'))) for line in output.splitlines()]

def machine():
    # Only non-sensitive model/display facts; no serial number or user information.
    scale = checked(['/usr/bin/osascript', '-l', 'JavaScript', '-e',
        "ObjC.import('AppKit'); Number($.NSScreen.mainScreen.backingScaleFactor)"])
    return dict(model=checked(['/usr/sbin/sysctl', '-n', 'hw.model']),
                chip=checked(['/usr/sbin/sysctl', '-n', 'machdep.cpu.brand_string']),
                memory=checked(['/usr/sbin/sysctl', '-n', 'hw.memsize']),
                macOS=checked(['/usr/bin/sw_vers', '-productVersion']), scale=float(scale))

def logs(run, pid):
    start = (run / 'start.txt').read_text().strip()
    r = command(['/usr/bin/log', 'show', '--start', start, '--style', 'compact', '--info',
                 '--predicate', f'subsystem == "io.github.anzchy.mado" AND processID == {pid}'])
    if r.returncode:
        raise RuntimeError(r.stderr.strip())
    (run / 'app.log').write_text(r.stdout)
    return r.stdout

def atomic_text(path, text):
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode='w', dir=path.parent, prefix='.' + path.name, delete=False) as output:
            temporary = Path(output.name)
            output.write(text)
        os.replace(temporary, path)
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()

def save(run, name, data):
    atomic_text(run / name, json.dumps(data, indent=2) + '\n')

INPUT_ROOTS = ('App', 'Packages', 'project.yml', 'UITests', 'TestAssets', 'Info.plist', 'Resources', 'resources')

def is_input(relative):
    path = Path(relative)
    return (not any(part in ('.build', '.git', '__pycache__', 'DerivedData') for part in path.parts)
            and (path.parts[0] in INPUT_ROOTS or path.suffix == '.entitlements'))

def input_inventory(root=ROOT):
    paths = []
    for name in INPUT_ROOTS:
        p = root / name
        if p.is_file() or p.is_symlink(): paths.append(p)
        elif p.is_dir(): paths.extend(p.rglob('*'))
    paths.extend(root.glob('*.entitlements'))
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in paths if p.is_file() and is_input(p.relative_to(root))}

def assert_clean_inputs(root=ROOT):
    inventory = input_inventory(root)
    tracked = set(checked(['git', '-C', root, 'ls-files', '-z']).split('\0'))
    tracked = {name for name in tracked if name and is_input(name)}
    if set(inventory) != tracked:
        raise RuntimeError('untracked or missing build inputs: ' + ', '.join(sorted(set(inventory) ^ tracked)))
    if command(['git', '-C', root, 'diff', '--quiet', 'HEAD', '--', *sorted(tracked)]).returncode:
        raise RuntimeError('modified build inputs; commit before building')
    return inventory

def run_dir(value):
    run = Path(value).expanduser().resolve()
    if run == ROOT or run.is_relative_to(ROOT):
        raise RuntimeError('run evidence must be outside the worktree')
    run.mkdir(parents=True, exist_ok=True)
    return run

def signing_identity(app):
    # Re-sign with the exact certificate xcodebuild chose for the team; the name
    # "Apple Development" is ambiguous once the keychain holds another team's identity.
    with tempfile.TemporaryDirectory(prefix='mado-sign-') as folder:
        prefix = Path(folder) / 'cert'
        checked(['/usr/bin/codesign', '-d', '--extract-certificates=' + str(prefix), app])
        leaf = Path(str(prefix) + '0')
        if not leaf.exists():
            raise RuntimeError('built app has no signing certificate to re-sign with')
        return hashlib.sha1(leaf.read_bytes()).hexdigest().upper()

def build(run):
    if running():
        raise RuntimeError('another Mado is running; ask its owner to quit it')
    inputs = assert_clean_inputs(ROOT)
    xcode, version = select_xcode()
    os.environ['DEVELOPER_DIR'] = str(xcode / 'Contents/Developer')
    sha = checked(['git', '-C', ROOT, 'rev-parse', '--short', 'HEAD'])
    full = checked(['git', '-C', ROOT, 'rev-parse', 'HEAD'])
    dd = ROOT / '.build' / ('device-' + run.name)
    with (run / 'build.log').open('w') as output:
        for argv in [['xcodegen', 'generate'], ['/usr/bin/xcodebuild', 'build', '-scheme', 'Mado',
                     '-configuration', 'Debug', '-destination', 'platform=macOS', '-derivedDataPath', str(dd)]]:
            r = subprocess.run(argv, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT)
            if r.returncode:
                raise RuntimeError(f'build failed; see {run / "build.log"}')
    if inputs != assert_clean_inputs(ROOT) or full != checked(['git', '-C', ROOT, 'rev-parse', 'HEAD']):
        raise RuntimeError('build inputs or commit changed during build; refusing proof image')
    app = dd / 'Build/Products/Debug/Mado.app'
    # The inherited stamp marks all tracked metadata edits dirty. Only normalize after
    # verifying every binary input against HEAD, then restore the development signature.
    plist = app / 'Contents/Info.plist'
    if plistlib.loads(plist.read_bytes()).get('MadoGitSHA') != sha:
        checked(['/usr/libexec/PlistBuddy', '-c', 'Set :MadoGitSHA ' + sha, plist])
        checked(['/usr/bin/codesign', '--force', '--sign', signing_identity(app),
                 '--preserve-metadata=entitlements,requirements,flags,runtime', app])
    if inputs != assert_clean_inputs(ROOT):
        raise RuntimeError('build inputs changed during signing')
    (run / 'bundle.path').write_text(str(app) + '\n')
    save(run, 'build.json', dict(sha=sha, fullSHA=full, machine=machine(), configuration='Debug', xcode=version, inputs=inputs))
    print(f'PASS build bundle={app} git={sha}')

def launch(run):
    if (run / 'process.json').exists() or (run / 'retired').exists():
        raise RuntimeError('run already has an ownership record; use a new run directory')
    before = set(running())
    if before:
        raise RuntimeError('another Mado is running; ask its owner to quit it')
    app = Path((run / 'bundle.path').read_text().strip()).resolve()
    sha = json.loads((run / 'build.json').read_text())['sha']
    argv = ['/usr/bin/open', '-n', '-W', str(app)]
    # Optional per-run UI language (evidence stays in the run directory); no system setting changes.
    if (run / 'app-lang.txt').exists():
        lang = (run / 'app-lang.txt').read_text().strip()
        if not re.fullmatch(r'[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*', lang):
            raise RuntimeError('app-lang.txt is not a language tag')
        argv += ['--args', '-AppleLanguages', f'({lang})']
    launch_time = time.time()
    (run / 'start.txt').write_text(datetime.datetime.fromtimestamp(launch_time).strftime('%Y-%m-%d %H:%M:%S'))
    # -W keeps the LaunchServices helper alive until the new app exits, so an
    # exit before our first PID sample is observable without launching the
    # bundle executable directly.
    opener = subprocess.Popen(argv, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              env={**os.environ, 'LC_ALL': 'C'})
    deadline = time.monotonic() + 30
    missing = 'process'
    while time.monotonic() < deadline:
        if opener.poll() is not None:
            _, diagnostic = opener.communicate()
            raise RuntimeError('LaunchServices app exited before readiness'
                               + (': ' + diagnostic.strip() if diagnostic.strip() else ''))
        candidates = [p for p in running() if p not in before and executable(p) == app / 'Contents/MacOS/Mado']
        if len(candidates) > 1:
            raise RuntimeError('more than one new matching Mado process; no PID recorded')
        if not candidates and (run / 'process.json').exists():
            raise RuntimeError('launched process exited after identity was recorded')
        if candidates:
            pid = candidates[0]
            if not (run / 'process.json').exists():
                record = process_snapshot(pid)
                if record is None:
                    raise RuntimeError('launched process disappeared before birth identity was recorded')
                birth = datetime.datetime.strptime(record['birth'], '%a %b %d %H:%M:%S %Y').timestamp()
                # ps lstart has second precision. Accept the launch second, while the
                # pre-open PID snapshot excludes processes already present.
                if (record['pid'] != pid or not inside(Path(record['executable']), app)
                        or birth < int(launch_time)):
                    raise RuntimeError('new process identity or birth differs from this launch')
                (run / 'picsee.pid').write_text(str(pid) + '\n')
                save(run, 'process.json', record)
            elif pid != json.loads((run / 'process.json').read_text())['pid']:
                raise RuntimeError('launched process identity changed')
            identity(run)
            ws = windows(pid)  # Authorization failures stop immediately; never dismiss prompts.
            visible = checked(['/usr/bin/osascript', '-l', 'JavaScript', HERE / 'winid.js', str(pid)])
            log = logs(run, pid)
            if len(ws) == 1 and ws[0]['title'] == 'Mado' and visible and f'Mado launch git={sha}' in log:
                save(run, 'ready.json', ws)
                print(f'PASS ready pid={pid} title=Mado git={sha}')
                return
            missing = 'visible Mado window or public launch SHA log'
        time.sleep(0.5)
    raise RuntimeError('ready timeout after 30 s: missing ' + missing)

def sandbox_enabled(output):
    # codesign :- requests XML explicitly; do not parse the default human-readable dump.
    try:
        raw = output.encode() if isinstance(output, str) else output
        return plistlib.loads(raw).get('com.apple.security.app-sandbox') is True
    except Exception:
        return False

CHECKS = ('build-sha', 'bundle-id', 'signature-team', 'signature-valid', 'sandbox', 'process-bundle',
          'fresh-sources', 'single-instance', 'window', 'launch-log', 'machine', 'fixtures')

def collect(run, expected):
    data = dict(expectedSHA=expected, errors={})
    def observe(names, action, default=None):
        try:
            return action()
        except Exception as e:
            for name in names:
                data['errors'][name] = str(e)
            return default
    app = observe(('build-sha', 'bundle-id', 'signature-team', 'signature-valid', 'sandbox', 'fresh-sources'),
                  lambda: Path((run / 'bundle.path').read_text().strip()).resolve())
    info = observe(('build-sha', 'bundle-id'),
                   lambda: plistlib.loads((app / 'Contents/Info.plist').read_bytes()), {})
    data.update(sha=info.get('MadoGitSHA'), bundleID=info.get('CFBundleIdentifier'))
    def team():
        r = command(['/usr/bin/codesign', '-dv', '--verbose=2', app])
        if r.returncode: raise RuntimeError(r.stderr)
        match = re.search(r'TeamIdentifier=(\S+)', r.stderr)
        return match.group(1) if match else None
    data['team'] = observe(('signature-team',), team)
    def signature():
        checked(['/usr/bin/codesign', '--verify', '--deep', '--strict', app])
        return True
    data['signatureValid'] = observe(('signature-valid',), signature, False)
    data['sandbox'] = observe(('sandbox',), lambda: sandbox_enabled(checked(
        ['/usr/bin/codesign', '-d', '--entitlements', ':-', app])), False)
    owned = observe(('process-bundle', 'single-instance', 'window', 'launch-log'), lambda: identity(run))
    data['processMatches'] = owned is not None and owned[1] == app
    data['alone'] = observe(('single-instance',), lambda: owned is not None and running() == [owned[0]], False)
    data['windows'] = observe(('window',), lambda: windows(owned[0]), []) if owned else []
    if owned and not data['windows'] and 'window' not in data['errors']:
        data['errors']['window'] = '0 windows'
    data['log'] = observe(('launch-log',), lambda: logs(run, owned[0]), '') if owned else ''
    recorded = observe(('machine', 'fresh-sources'), lambda: json.loads((run / 'build.json').read_text()), {})
    data['machine'] = observe(('machine',), machine)
    data['machineMatches'] = data['machine'] is not None and data['machine'] == recorded.get('machine')
    def fresh():
        current = assert_clean_inputs(ROOT)
        stamp = (app / 'Contents/Info.plist').stat().st_mtime_ns
        return (current == recorded['inputs'] and
                all((ROOT / name).stat().st_mtime_ns <= stamp for name in current))
    data['fresh'] = observe(('fresh-sources',), fresh, False)
    def fixtures():
        files = [p for p in (run / 'fixtures').rglob('*') if p.is_file()]
        manifest = run / 'fixtures.sha256.json'
        if not manifest.exists(): return not files, []
        expected_hashes = json.loads(manifest.read_text())
        intact = {str(p.relative_to(run / 'fixtures')): hashlib.sha256(p.read_bytes()).hexdigest()
                  for p in files} == expected_hashes
        return intact, list(expected_hashes)
    data['fixturesIntact'], data['fixtureNames'] = observe(('fixtures',), fixtures, (False, []))
    if owned:
        observe(('process-bundle', 'single-instance', 'window', 'launch-log'), lambda: identity(run))
    save(run, 'doctor-input.json', data)
    return data

def verdicts(data):
    windows_seen = data.get('windows', [])
    window_title = windows_seen[0].get('title') if len(windows_seen) == 1 else None
    fixture_titles = {Path(name).name for name in data.get('fixtureNames', [])}
    window_ok = window_title == 'Mado' or window_title in fixture_titles
    checks = [
        ('build-sha', data.get('sha') == data.get('expectedSHA') and bool(data.get('expectedSHA')), 'MadoGitSHA differs from expected SHA'),
        ('bundle-id', data.get('bundleID') == 'io.github.anzchy.mado', 'wrong bundle identifier'),
        ('signature-team', data.get('team') == 'GRT84NAK4T', 'wrong signing team'),
        ('signature-valid', data.get('signatureValid') is True, 'codesign verification failed'),
        ('sandbox', data.get('sandbox') is True, 'App Sandbox entitlement missing'),
        ('process-bundle', data.get('processMatches') is True, 'PID executable differs from recorded bundle'),
        ('fresh-sources', data.get('fresh') is True, 'build input modified, missing, untracked or newer than bundle'),
        ('single-instance', data.get('alone') is True, 'recorded PID is not the only Mado instance'),
        ('window', len(windows_seen) == 1 and window_ok, 'expected one window titled Mado or a recorded fixture file'),
        ('launch-log', bool(re.search(r'Mado launch git=' + re.escape(str(data.get('expectedSHA'))) + r'(?![\w-])', data.get('log', ''))), 'public SHA launch log missing'),
        ('machine', data.get('machineMatches') is True, 'machine/display differs from build record'),
        ('fixtures', data.get('fixturesIntact') is True, 'fixture hashes missing or changed')]
    checks = [(name, ok and name not in data.get('errors', {}), why) for name, ok, why in checks]
    lines = [('PASS ' + name + (f' — title={window_title}' if name == 'window' else '') if ok
              else 'FAIL ' + name + ' — ' + ' '.join(str(data.get('errors', {}).get(name, why)).split()))
             for name, ok, why in checks]
    return lines, all(ok for _, ok, _ in checks)

def cleanup(run):
    try:
        pid, app, record = recorded_identity(run)
        current = process_snapshot(pid)
        if current is None:
            print(f'PASS cleanup pid={pid} already exited; evidence retained at {run}')
            return
        if current != record:
            raise RuntimeError('process identity differs from recorded birth, PID or executable')
        # Last identity read immediately before the signal; never search/kill by name.
        if process_snapshot(pid) != record:
            raise RuntimeError('process identity changed; refusing signal')
        os.kill(pid, signal.SIGTERM)
        for _ in range(50):
            if process_snapshot(pid) != record:
                print(f'PASS cleanup terminated pid={pid}; evidence retained at {run}')
                return
            time.sleep(0.1)
        raise RuntimeError(f'PID {pid} did not exit after SIGTERM; no escalation sent')
    finally:
        atomic_text(run / 'retired', 'Cleanup attempted; ownership record is permanently retired.\n')

def doctor(run, expected=None, fixture=None):
    try:
        data = json.loads(Path(fixture).read_text()) if fixture else collect(
            run, expected or checked(['git', '-C', ROOT, 'rev-parse', '--short', 'HEAD']))
        lines, passed = verdicts(data)
    except Exception as e:
        data = dict(errors={name: str(e) for name in CHECKS})
        lines, passed = verdicts(data)
    output = '\n'.join(lines) + '\n'
    print(output, end='', flush=True)
    if run:
        report = run / 'doctor.txt'
        try:
            atomic_text(report, output)
        except Exception as e:
            status = 'no current report saved'
            try:
                if report.exists():
                    os.replace(report, run / 'doctor.stale.txt')
                    status = 'previous report moved to doctor.stale.txt (unusable)'
            except OSError:
                try:
                    report.unlink()
                    status = 'previous report removed'
                except OSError:
                    status = 'existing doctor.txt is STALE/UNUSABLE; storage prevents invalidation'
            why = ' '.join(str(e).split())
            print(f'FAIL report-write — {why}; {status}')
            return 1
    return 0 if passed else 1

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['build', 'launch', 'doctor', 'cleanup'])
    parser.add_argument('run', nargs='?')
    parser.add_argument('--expected-sha')
    parser.add_argument('--fixture', help='offline doctor input only; never device proof')
    args = parser.parse_args()
    try:
        if args.action == 'doctor':
            run = None if args.fixture else run_dir(args.run)
            return doctor(run, args.expected_sha, args.fixture)
        globals()[args.action](run_dir(args.run))
        return 0
    except Exception as e:
        print(f'FAIL {args.action} — {e}')
        return 1

if __name__ == '__main__':
    sys.exit(main())
