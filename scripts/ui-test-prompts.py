#!/usr/bin/env python3
"""Read UserNotificationCenter windows; stop only this UI run when one appears."""
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import time

WINDOWS = r'''
ObjC.import('CoreGraphics');
ObjC.import('Foundation');
var rows = ObjC.deepUnwrap(ObjC.castRefToObject(
  $.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly, 0)));
JSON.stringify(rows.filter(function(w) {
  return w.kCGWindowOwnerName === 'UserNotificationCenter';
}).map(function(w) {
  return {owner: w.kCGWindowOwnerName, pid: w.kCGWindowOwnerPID,
    window: w.kCGWindowNumber, title: w.kCGWindowName || '<window title unavailable>'};
}));
'''


def windows():
    result = subprocess.run(['/usr/bin/osascript', '-l', 'JavaScript', '-e', WINDOWS],
                            check=True, capture_output=True, text=True, timeout=5)
    return json.loads(result.stdout)


def processes():
    output = subprocess.check_output(['/bin/ps', '-axo', 'pid=,command='], text=True)
    return {int(line.split(None, 1)[0]): line.split(None, 1)[1]
            for line in output.splitlines() if len(line.split(None, 1)) == 2}


def stop_run(result_path, derived, baseline):
    # Never signal an App that predates this watch or an executable from another build.
    app = str(Path(derived) / 'Build/Products/Debug/Mado.app/Contents/MacOS/Mado')
    fixture_prefix = Path(result_path).parent.name + '-'
    for pid, command in processes().items():
        if pid in baseline or pid == os.getpid():
            continue
        if result_path not in command and app not in command:
            continue
        try:
            args = shlex.split(command)
        except ValueError:
            continue
        if not args:
            continue
        own_heavy = (len(args) > 1 and Path(args[0]).name.lower().startswith('python')
                     and args[1] == str(Path(__file__).resolve().parent / 'tdd/heavy-lock.py'))
        own_build = result_path in args and (Path(args[0]).name == 'xcodebuild' or own_heavy)
        own_app = False
        if args[0] == app and '-MadoUITestFixture' in args:
            index = args.index('-MadoUITestFixture') + 1
            own_app = index < len(args) and args[index].startswith(fixture_prefix)
        if own_build or own_app:
            try:
                os.kill(pid, signal.SIGTERM)
                print(f'Prompt guard stopped this run PID={pid}', flush=True)
            except ProcessLookupError:
                pass


def main():
    if len(sys.argv) == 2 and sys.argv[1] == 'check':
        found = windows()
        print(json.dumps({'UserNotificationCenterWindows': found}, ensure_ascii=False))
        return 78 if found else 0
    if len(sys.argv) != 7 or sys.argv[1] != 'watch':
        raise SystemExit('usage: ui-test-prompts.py check | watch <result> <derived> <stop-file> <evidence> <ready-file>')
    result, derived, stop, evidence, ready = sys.argv[2:]
    baseline = processes()
    triggered = False
    while not Path(stop).exists():
        if triggered:
            # Keep guarding the launch gap until the parent acknowledges stop.
            # A queued heavy job may not have existed at first detection.
            stop_run(result, derived, baseline)
            time.sleep(0.1)
            continue
        try:
            found = windows()
            if not found:
                Path(ready).touch()
                time.sleep(1)
                continue
            report = {'UserNotificationCenterWindows': found}
        except Exception as error:
            report = {'promptMonitorError': str(error)}
        Path(evidence).write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
        print('UI run stopped: ' + json.dumps(report, ensure_ascii=False), flush=True)
        triggered = True
        stop_run(result, derived, baseline)
    return 78 if triggered else 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as error:
        print('Cannot verify UserNotificationCenter windows: ' + str(error), file=sys.stderr)
        sys.exit(78)
