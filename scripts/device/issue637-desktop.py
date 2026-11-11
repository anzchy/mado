#!/usr/bin/env python3
"""#637 WindowServer regression. Run from a Screen Recording-authorized Terminal.app.

    python3 scripts/device/issue637-desktop.py run --out ~/.picsee/device-runs/i637-<id>

The run builds and launches the committed signed app, drives its real Settings,
opens generated file-grant images, saves window captures, and writes verdict.json.
Use --source to build another clean worktree (including e87b71cd) with this runner.
"""
import argparse
import ctypes
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess
import sys
import time
import zlib

HERE = Path(__file__).resolve().parent
SRGB_PROFILE = Path('/System/Library/ColorSync/Profiles/sRGB Profile.icc')
THEMES = ('light', 'dark')
GREYS = (69, 226)
TIERS = (30, 50, 100)
PAGES = ('14', '16')  # Page 33 Filmstrip is not implemented (PREF-04).
GROUPS = ('left', 'middle', 'right')


class EnvironmentFailure(Exception):
    pass


def invoke(argv, *, timeout=120, cwd=None):
    result = subprocess.run([str(part) for part in argv], cwd=cwd, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    if result.returncode:
        raise EnvironmentFailure(f'{argv[0]} exit {result.returncode}: '
                                 f'{(result.stderr or result.stdout).strip()[-1200:]}')
    return result.stdout.strip()


def png(path):
    """Read 8-bit, noninterlaced RGB/RGBA PNG after ColorSync normalization."""
    raw = Path(path).read_bytes()
    if not raw.startswith(b'\x89PNG\r\n\x1a\n'):
        raise EnvironmentFailure(f'not PNG: {path}')
    pos, data, width, height, channels = 8, bytearray(), None, None, None
    while pos < len(raw):
        if pos + 12 > len(raw):
            raise EnvironmentFailure(f'truncated PNG: {path}')
        length = struct.unpack_from('>I', raw, pos)[0]
        kind = raw[pos + 4:pos + 8]
        end = pos + 12 + length
        if end > len(raw):
            raise EnvironmentFailure(f'truncated PNG chunk: {path}')
        payload = raw[pos + 8:pos + 8 + length]
        crc = struct.unpack_from('>I', raw, pos + 8 + length)[0]
        if zlib.crc32(kind + payload) & 0xffffffff != crc:
            raise EnvironmentFailure(f'PNG CRC failure: {path}')
        if kind == b'IHDR':
            width, height, depth, color, comp, filt, interlace = struct.unpack('>IIBBBBB', payload)
            if depth != 8 or color not in (2, 6) or comp or filt or interlace:
                raise EnvironmentFailure(f'unsupported PNG layout: {path}')
            channels = 3 if color == 2 else 4
        elif kind == b'IDAT':
            data.extend(payload)
        elif kind == b'IEND':
            break
        pos = end
    if not width or not height or width > 16384 or height > 16384 or not data:
        raise EnvironmentFailure(f'incomplete PNG: {path}')
    try:
        stream = zlib.decompress(data)
    except zlib.error as error:
        raise EnvironmentFailure(f'PNG inflate failure: {path}: {error}') from error
    stride = width * channels
    if len(stream) != height * (stride + 1):
        raise EnvironmentFailure(f'PNG row count mismatch: {path}')
    rows, previous, cursor = [], bytearray(stride), 0
    for _ in range(height):
        method = stream[cursor]
        row = bytearray(stream[cursor + 1:cursor + stride + 1])
        cursor += stride + 1
        if method > 4:
            raise EnvironmentFailure(f'unsupported PNG filter: {path}')
        for i in range(stride):
            left = row[i - channels] if i >= channels else 0
            up = previous[i]
            upper_left = previous[i - channels] if i >= channels else 0
            if method == 1:
                row[i] = (row[i] + left) & 255
            elif method == 2:
                row[i] = (row[i] + up) & 255
            elif method == 3:
                row[i] = (row[i] + (left + up) // 2) & 255
            elif method == 4:
                prediction = left + up - upper_left
                distances = (abs(prediction - left), abs(prediction - up), abs(prediction - upper_left))
                predictor = (left, up, upper_left)[distances.index(min(distances))]
                row[i] = (row[i] + predictor) & 255
        rows.append(bytes(row))
        previous = row
    return width, height, channels, rows


def pixel(image, x, y):
    width, height, channels, rows = image
    if not (0 <= x < width and 0 <= y < height):
        raise EnvironmentFailure(f'pixel ({x},{y}) outside {width}x{height}')
    index = x * channels
    rgba = rows[y][index:index + channels]
    if channels == 4 and rgba[3] < 255:
        raise EnvironmentFailure(f'window capture pixel ({x},{y}) is transparent')
    return tuple(rgba[:3])


def chunk(kind, payload):
    return struct.pack('>I', len(payload)) + kind + payload + struct.pack('>I', zlib.crc32(kind + payload) & 0xffffffff)


def fixture(path, mode, grey=0):
    width, height = 960, 640
    rows = []
    for _y in range(height):
        row = bytearray()
        for x in range(width):
            shade = grey if mode == 'flat' else (0 if (x // 4) % 2 else 255)
            row.extend((shade, shade, shade))
        rows.append(b'\0' + row)
    body = b'\x89PNG\r\n\x1a\n'
    body += chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))
    body += chunk(b'sRGB', b'\0')
    body += chunk(b'IDAT', zlib.compress(b''.join(rows), 9))
    Path(path).write_bytes(body + chunk(b'IEND', b''))


def normalized_shot(run, source_script, label):
    invoke([source_script / 'shot.sh', run, label], timeout=30)
    original = run / 'shots' / (label + '.png')
    if not original.exists() or original.stat().st_size < 100:
        raise EnvironmentFailure(f'missing capture {label}')
    target = run / 'srgb' / (label + '.png')
    target.parent.mkdir(exist_ok=True)
    invoke(['/usr/bin/sips', '-m', SRGB_PROFILE, '--out', target, original], timeout=30)
    profile = invoke(['/usr/bin/sips', '-g', 'profile', target])
    if 'sRGB' not in profile:
        raise EnvironmentFailure(f'capture is not tagged sRGB: {label}: {profile}')
    png(target)
    return str(target)


def ax(pid, operation, identifier, value=None):
    args = ['/usr/bin/osascript', '-l', 'JavaScript', HERE / 'issue637-ax.js',
            pid, operation, identifier]
    if value is not None:
        args.append(value)
    started = time.monotonic()
    try:
        return invoke(args, timeout=12)
    except (EnvironmentFailure, subprocess.TimeoutExpired) as error:
        elapsed = time.monotonic() - started
        windows = 'unavailable'
        if operation != 'window-list':
            try:
                windows = invoke(['/usr/bin/osascript', '-l', 'JavaScript',
                                  HERE / 'issue637-ax.js', pid, 'window-list', 'window'], timeout=5)
            except (EnvironmentFailure, subprocess.TimeoutExpired) as diagnostic:
                windows = f'unavailable ({diagnostic})'
        raise EnvironmentFailure(f'AX {operation} identifier={identifier} elapsed={elapsed:.2f}s '
                                 f'windows=[{windows}]: {error}') from error


def key(source, run, character, *modifiers):
    invoke([source / 'key.sh', run, character, *modifiers], timeout=15)


def escape(source, run):
    invoke([source / 'kc.sh', run, 53], timeout=15)


def settings(source, run, pid):
    key(source, run, ',', 'command')
    deadline = time.monotonic() + 8
    last_error = None
    while time.monotonic() < deadline:
        try:
            window = ax(pid, 'settings-window', 'window')
            break
        except EnvironmentFailure as error:
            last_error = error
            time.sleep(.2)
    else:
        raise EnvironmentFailure(f'Settings window did not open within 8s: {last_error}')
    try:
        ax(pid, 'value', 'settings.section.general')
    except EnvironmentFailure as error:
        raise EnvironmentFailure(f'{window}; Settings sidebar lookup failed: {error}') from error
    return window


def close_settings(source, run):
    escape(source, run)
    time.sleep(.2)


def set_theme(source, run, pid, theme):
    settings(source, run, pid)
    ax(pid, 'press', 'settings.section.general')
    ax(pid, 'press', 'settings.appearance.' + theme)
    close_settings(source, run)


def set_opacity(source, run, pid, opacity):
    settings(source, run, pid)
    ax(pid, 'press', 'settings.section.display')
    ax(pid, 'set-slider', 'settings.display.tool-opacity', opacity)
    value = ax(pid, 'value', 'settings.display.tool-opacity.value')
    if str(opacity) not in value:
        raise EnvironmentFailure(f'opacity label did not update to {opacity}: {value}')
    close_settings(source, run)


def set_always_show(source, run, pid, desired):
    settings(source, run, pid)
    ax(pid, 'press', 'settings.section.general')
    current = ax(pid, 'value', 'settings.always-show-tools').lower() in ('1', 'true', 'on')
    if current != desired:
        ax(pid, 'press', 'settings.always-show-tools')
    actual = ax(pid, 'value', 'settings.always-show-tools').lower() in ('1', 'true', 'on')
    if actual != desired:
        raise EnvironmentFailure(f'Always Show Image Tools did not become {desired}')
    close_settings(source, run)


def open_fixture(source, run, path):
    app = Path((run / 'bundle.path').read_text().strip())
    invoke(['/usr/bin/open', '-a', app, path], timeout=15)
    pid = int((run / 'picsee.pid').read_text())
    for _ in range(50):
        try:
            title = ax(pid, 'window-title', 'window')
            if Path(path).name in title:
                return
        except EnvironmentFailure:
            pass
        time.sleep(.2)
    raise EnvironmentFailure(f'fixture did not appear in owned viewer: {path}')


def sample_points(image):
    width, height, _channels, _rows = image
    if width < 800 or height < 550 or width / height < 1.1:
        raise EnvironmentFailure(f'wrong window capture dimensions: {width}x{height}')
    scale = width / 960
    if min(abs(scale - 1), abs(scale - 2)) > .025:
        raise EnvironmentFailure(f'unsupported window scale/width: {width}x{height}')
    s = round(scale)
    # Full-size-content window, clear of controls, labels, border and rounded corners.
    y = height - 48 * s
    return {group: (round(x * s), y) for group, x in
            (('left', 36), ('middle', 480), ('right', 790))}, (round(250 * s), height - 8 * s), s


def analyze(manifest):
    manifest = Path(manifest)
    record = json.loads(manifest.read_text())
    captures = record.get('captures', {})
    expected_keys = [f'{page}-{theme}-{grey}-{opacity}' for page in PAGES
                     for theme in THEMES for grey in GREYS for opacity in TIERS]
    missing = sorted(set(expected_keys) - set(captures))
    if missing:
        raise EnvironmentFailure('missing captures: ' + ', '.join(missing))
    images = {key: png(captures[key]) for key in expected_keys}
    rows, failures = [], []
    for page in PAGES:
        for theme in THEMES:
            for grey in GREYS:
                baseline = images[f'{page}-{theme}-{grey}-100']
                positions, background, scale = sample_points(baseline)
                for opacity in TIERS:
                    key = f'{page}-{theme}-{grey}-{opacity}'
                    image = images[key]
                    if image[:2] != baseline[:2]:
                        raise EnvironmentFailure(f'wrong capture dimensions for {key}')
                    backdrop = pixel(image, *background)
                    if any(abs(c - grey) > 2 for c in backdrop):
                        raise EnvironmentFailure(f'wrong image/frame at {key}: backdrop {backdrop}, expected {grey}')
                    for group in GROUPS:
                        point = positions[group]
                        observed = pixel(image, *point)
                        panel = pixel(baseline, *point)
                        target = .5 + .5 * opacity / 100
                        stable = [(channel, (observed[i] - backdrop[i]) / (panel[i] - backdrop[i]))
                                  for i, channel in enumerate('rgb') if abs(panel[i] - backdrop[i]) > 30]
                        reasons = []
                        if opacity == 100:
                            design = (255, 255, 255) if theme == 'light' else (20, 24, 33)
                            if any(abs(observed[i] - design[i]) > 2 for i in range(3)):
                                reasons.append(f'opaque RGB {observed} differs from design {design} by >2/255')
                        elif stable:
                            if any(abs(value - target) > .05 for _, value in stable):
                                reasons.append(f'coverage {stable} outside {target:.2f}±0.05')
                        elif not (theme == 'light' and grey == 226):
                            reasons.append('all RGB channels numerically unstable')
                        row = dict(page=page, appearance=theme, grey=grey, preference=opacity,
                                   group=group, point=point, backdrop=backdrop, pill=observed,
                                   panelRGB=panel, stableCoverage=stable, expectedCoverage=target,
                                   omitted='unstable—coverage omitted' if not stable else None,
                                   scale=scale, failures=reasons)
                        rows.append(row)
                        failures.extend(f'{key}/{group}: {reason}' for reason in reasons)
    if len(rows) != 72:
        raise EnvironmentFailure(f'incomplete sample matrix: {len(rows)} of 72')
    for extra in ('pattern-light-30', 'pattern-light-100', 'pattern-light-zoom',
                  'replacement-light-69', 'active-light-69', 'inactive-light-69',
                  'hidden-light-69', 'wake-light-69'):
        if extra not in captures:
            raise EnvironmentFailure(f'missing capture: {extra}')
    pattern = png(captures['pattern-light-30'])
    pattern_opaque = png(captures['pattern-light-100'])
    zoomed = png(captures['pattern-light-zoom'])
    replacement = png(captures['replacement-light-69'])
    dynamic = {key: png(captures[key]) for key in
               ('active-light-69', 'inactive-light-69', 'hidden-light-69', 'wake-light-69')}
    if any(image[:2] != pattern[:2] for image in (pattern_opaque, zoomed, replacement, *dynamic.values())):
        raise EnvironmentFailure('pattern/zoom/replacement window dimensions changed')
    positions, background, scale = sample_points(pattern)
    smoothing = []
    for group in GROUPS:
        center, y = positions[group]
        inside = [pixel(pattern, x, y)[0] for x in range(center - 20 * scale, center + 21 * scale, scale)]
        outside = [pixel(pattern, x, background[1])[0]
                   for x in range(center - 20 * scale, center + 21 * scale, scale)]
        def variance(values):
            mean = sum(values) / len(values)
            return sum((value - mean) ** 2 for value in values) / len(values)
        outside_variance = variance(outside)
        if outside_variance < 1000:
            raise EnvironmentFailure(f'pattern source has no visible stripes near {group}')
        normalized_ratio = variance(inside) / ((1 - .65) ** 2 * outside_variance)
        smoothing.append(dict(group=group, outsideVariance=outside_variance,
                              normalizedInsideVarianceRatio=normalized_ratio))
        if normalized_ratio >= .35:
            failures.append(f'pattern/{group}: no visible blur, normalized variance ratio {normalized_ratio:.3f}')
    if any(abs(channel - 69) > 2 for channel in pixel(replacement, *background)):
        failures.append('image replacement did not publish grey69 canvas')
    width, height = pattern[:2]
    changed = sum(pixel(pattern_opaque, x, height // 2) != pixel(zoomed, x, height // 2)
                  for x in range(100 * scale, width - 100 * scale, 8 * scale))
    total = len(range(100 * scale, width - 100 * scale, 8 * scale))
    if total == 0 or changed / total < .05:
        failures.append('zoom did not change the canvas pattern')
    auto_hide = []
    for group, point in positions.items():
        hidden = pixel(dynamic['hidden-light-69'], *point)
        woken = pixel(dynamic['wake-light-69'], *point)
        backdrop = pixel(dynamic['hidden-light-69'], *background)
        if any(abs(hidden[i] - backdrop[i]) > 2 for i in range(3)):
            failures.append(f'auto-hide/{group}: hidden pixel {hidden} differs from canvas {backdrop}')
        if max(abs(woken[i] - hidden[i]) for i in range(3)) < 8:
            failures.append(f'auto-hide/{group}: Tab did not restore tool pod pixels')
        auto_hide.append(dict(group=group, hidden=hidden, woken=woken, backdrop=backdrop))
    return dict(status='FAIL' if failures else 'PASS', scope='implemented viewer pages 14 and 16',
                notVerified=['page 33 Filmstrip is unimplemented (PREF-04)',
                             'macOS 14 and other display scale require separate signed device runs',
                             'pan gesture and control contrast need separate device evidence',
                             'active/inactive captures need independent visual review'],
                sampleCount=len(rows), samples=rows, failures=failures,
                smoothing=smoothing, zoomChanged=changed, zoomSampleCount=total,
                autoHide=auto_hide, activeInactiveCaptured=True,
                captures=captures, source=record.get('source'), build=record.get('build'))


def capture(source, run, dry_ax=False):
    if not SRGB_PROFILE.exists():
        raise EnvironmentFailure('system sRGB profile unavailable')
    ax_framework = ctypes.CDLL('/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices')
    cg_framework = ctypes.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
    ax_framework.AXIsProcessTrusted.restype = ctypes.c_bool
    cg_framework.CGPreflightScreenCaptureAccess.restype = ctypes.c_bool
    if not ax_framework.AXIsProcessTrusted():
        raise EnvironmentFailure('Terminal.app lacks Accessibility; no AX actions made')
    if not dry_ax and not cg_framework.CGPreflightScreenCaptureAccess():
        raise EnvironmentFailure('Terminal.app lacks Screen Recording; no captures made')
    run.mkdir(parents=True, exist_ok=False)
    fixtures = run / 'fixtures'
    fixtures.mkdir()
    for grey in GREYS:
        fixture(fixtures / f'flat-{grey:03}.png', 'flat', grey)
    fixture(fixtures / 'pattern.png', 'pattern')
    (run / 'fixtures.sha256.json').write_text(json.dumps({p.name: hashlib.sha256(p.read_bytes()).hexdigest()
        for p in fixtures.iterdir()}, indent=2) + '\n')
    invoke([source / 'scripts/device/build.sh', run], timeout=7200, cwd=source)
    lock = source / '.agents/skills/picsee-delegator/scripts/gui-lock.sh'
    batch = run.name
    acquired = invoke([lock, 'acquire', batch, 90, 'issue637 WindowServer regression'])
    match = re.search(r'acquisition_id=([0-9a-f-]+)', acquired)
    if not match:
        raise EnvironmentFailure(f'GUI lock did not report acquisition ID: {acquired}')
    acquisition = match.group(1)
    active = False
    cleanup_error = None
    try:
        invoke([source / 'scripts/device/launch.sh', run], timeout=75)
        active = True
        invoke([source / 'scripts/device/doctor.sh', run], timeout=45)
        pid = int((run / 'picsee.pid').read_text())
        settings(source / 'scripts/device', run, pid)
        ax(pid, 'press', 'settings.section.display')
        original_opacity = int(float(ax(pid, 'value', 'settings.display.tool-opacity')))
        if dry_ax:
            # Exercise the writable AXSlider path without changing the preference.
            ax(pid, 'set-slider', 'settings.display.tool-opacity', original_opacity)
        ax(pid, 'press', 'settings.section.general')
        original = dict(opacity=original_opacity,
                        appearance=next((name for name in ('system', 'light', 'dark')
                            if ax(pid, 'value', 'settings.appearance.' + name).lower() in ('1', 'true', 'on')), None),
                        alwaysShow=ax(pid, 'value', 'settings.always-show-tools'))
        (run / 'original-preferences.json').write_text(json.dumps(original, indent=2) + '\n')
        if original['appearance'] is None:
            raise EnvironmentFailure('cannot identify original appearance preference')
        if dry_ax:
            close_settings(source / 'scripts/device', run)
            return dict(status='PASS', scope='Settings AX only', settingsWindow='present',
                        opacity=original_opacity, appearance=original['appearance'],
                        alwaysShow=original['alwaysShow'], sampleCount=0, samples=[], failures=[],
                        notVerified=['desktop pixel matrix was not run'])
        if original['alwaysShow'] not in ('1', 'true'):
            ax(pid, 'press', 'settings.always-show-tools')
        close_settings(source / 'scripts/device', run)
        captures = {}
        for theme in THEMES:
            set_theme(source / 'scripts/device', run, pid, theme)
            for grey in GREYS:
                open_fixture(source, run, fixtures / f'flat-{grey:03}.png')
                for opacity in TIERS:
                    set_opacity(source / 'scripts/device', run, pid, opacity)
                    time.sleep(.25)
                    label = f'14-{theme}-{grey}-{opacity}'
                    captures[label] = normalized_shot(run, source / 'scripts/device', label)
                    key(source / 'scripts/device', run, 'i', 'command')
                    time.sleep(.25)
                    label = f'16-{theme}-{grey}-{opacity}'
                    captures[label] = normalized_shot(run, source / 'scripts/device', label)
                    key(source / 'scripts/device', run, 'i', 'command')
        set_theme(source / 'scripts/device', run, pid, 'light')
        open_fixture(source, run, fixtures / 'pattern.png')
        for opacity in (30, 100):
            set_opacity(source / 'scripts/device', run, pid, opacity)
            label = f'pattern-light-{opacity}'
            captures[label] = normalized_shot(run, source / 'scripts/device', label)
        key(source / 'scripts/device', run, '+')
        captures['pattern-light-zoom'] = normalized_shot(run, source / 'scripts/device', 'pattern-light-zoom')
        open_fixture(source, run, fixtures / 'flat-069.png')
        captures['replacement-light-69'] = normalized_shot(run, source / 'scripts/device', 'replacement-light-69')
        set_opacity(source / 'scripts/device', run, pid, 30)
        captures['active-light-69'] = normalized_shot(run, source / 'scripts/device', 'active-light-69')
        invoke(['/usr/bin/osascript', '-e', 'tell application "Finder" to activate'])
        captures['inactive-light-69'] = normalized_shot(run, source / 'scripts/device', 'inactive-light-69')
        ax(pid, 'window-title', 'window')  # Restore the owned app's active window.
        set_always_show(source / 'scripts/device', run, pid, False)
        time.sleep(3)
        captures['hidden-light-69'] = normalized_shot(run, source / 'scripts/device', 'hidden-light-69')
        invoke([source / 'scripts/device/kc.sh', run, 48], timeout=15)  # Tab wakes the tools.
        captures['wake-light-69'] = normalized_shot(run, source / 'scripts/device', 'wake-light-69')
        set_always_show(source / 'scripts/device', run, pid, True)
        record = dict(source=str(source), build=json.loads((run / 'build.json').read_text()),
                      captures=captures, notVerified=['page 33 Filmstrip unimplemented'])
        manifest = run / 'capture-manifest.json'
        manifest.write_text(json.dumps(record, indent=2) + '\n')
        result = analyze(manifest)
        return result
    finally:
        if active:
            try:
                if (run / 'original-preferences.json').exists():
                    original = json.loads((run / 'original-preferences.json').read_text())
                    pid = int((run / 'picsee.pid').read_text())
                    if not dry_ax:
                        set_theme(source / 'scripts/device', run, pid, original['appearance'])
                        set_opacity(source / 'scripts/device', run, pid, original['opacity'])
                        if original['alwaysShow'] not in ('1', 'true'):
                            settings(source / 'scripts/device', run, pid)
                            ax(pid, 'press', 'settings.section.general')
                            ax(pid, 'press', 'settings.always-show-tools')
                            close_settings(source / 'scripts/device', run)
            except Exception as error:
                (run / 'preference-restore-error.txt').write_text(str(error) + '\n')
                cleanup_error = f'preference restore failed: {error}'
            try:
                invoke([source / 'scripts/device/cleanup.sh', run], timeout=30)
            except Exception as error:
                cleanup_error = f'owned-process cleanup failed: {error}'
        try:
            invoke([lock, 'release', batch, '--acquisition-id', acquisition], timeout=15)
        except Exception as error:
            cleanup_error = f'GUI-lock release failed: {error}'
        if cleanup_error:
            raise EnvironmentFailure(cleanup_error)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='mode', required=True)
    run = sub.add_parser('run')
    run.add_argument('--out', type=Path, required=True)
    run.add_argument('--source', type=Path, default=HERE.parent.parent)
    dry = sub.add_parser('dry-ax')
    dry.add_argument('--out', type=Path, required=True)
    dry.add_argument('--source', type=Path, default=HERE.parent.parent)
    review = sub.add_parser('analyze')
    review.add_argument('--manifest', type=Path, required=True)
    review.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    output = args.out.expanduser().resolve()
    try:
        if args.mode in ('run', 'dry-ax'):
            source = args.source.expanduser().resolve()
            if output == source or output.is_relative_to(source):
                raise EnvironmentFailure('run evidence must be outside source worktree')
            result = capture(source, output, dry_ax=args.mode == 'dry-ax')
            verdict_path = output / 'verdict.json'
        else:
            result = analyze(args.manifest)
            verdict_path = output
        code = 0 if result['status'] == 'PASS' else 1
    except Exception as error:
        result = dict(status='ENVIRONMENT', reason=str(error), sampleCount=0, samples=[], failures=[],
                      notVerified=['device run incomplete'])
        verdict_path = output / 'verdict.json' if args.mode in ('run', 'dry-ax') else output
        code = 70
    verdict_path.parent.mkdir(parents=True, exist_ok=True)
    verdict_path.write_text(json.dumps(result, indent=2) + '\n')
    print(f"{result['status']} issue637 samples={result['sampleCount']} verdict={verdict_path}")
    if result.get('reason'):
        print(result['reason'], file=sys.stderr)
    return code


if __name__ == '__main__':
    sys.exit(main())
