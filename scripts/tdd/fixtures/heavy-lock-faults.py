"""Deterministic faults for the current process registry and mdpro acquisition."""
import importlib.util
import os
from pathlib import Path
import signal
import sys
from unittest.mock import patch

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('launcher', sys.argv[1])
launcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(launcher)
mode = sys.argv[2]
lock = Path(os.environ['MADO_MDPRO_LOCK'])

if mode == 'survivors':
    class Child:
        def poll(self): return 3
    ticks = [0]
    signals = []
    def clock():
        ticks[0] += 1
        return ticks[0]
    with patch.object(launcher.time, 'monotonic', side_effect=clock), \
         patch.object(launcher.time, 'sleep'), \
         patch.object(launcher, 'owned_state', return_value=[(123456789, 123456789)]), \
         patch.object(launcher, 'signal_owned', side_effect=lambda rows, sig: signals.append(sig)):
        assert launcher.stop_owned(Child(), 123456789, set(), set(), 0, None, 0) is False
    assert signals[:2] == [signal.SIGTERM, signal.SIGKILL], signals
    assert ticks[0] < 20, 'post-KILL observation must be bounded'
elif mode == 'publication':
    original = Path.write_text
    def fail_owner(path, *args, **kwargs):
        if path.name == 'owner': raise FileNotFoundError('peer reclaimed before publication')
        return original(path, *args, **kwargs)
    with patch.object(Path, 'write_text', fail_owner):
        assert launcher.acquire_shared(lock, launcher.time.monotonic(), [], ['fake-job']) is False
    assert lock.is_dir()
elif mode == 'heartbeat':
    ticks = [0]
    def clock():
        ticks[0] += 31
        return ticks[0]
    with patch.object(launcher.time, 'monotonic', side_effect=clock), \
         patch.object(launcher.time, 'sleep'):
        assert launcher.acquire_shared(lock, 100, [], ['fake-job']) is False
elif mode == 'vanished':
    original_mkdir = launcher.os.mkdir
    raced = [False]
    def mkdir(path, *args, **kwargs):
        if Path(path) == lock and not raced[0]:
            raced[0] = True
            assert not lock.exists()
            raise FileExistsError('peer moved lock after collision')
        return original_mkdir(path, *args, **kwargs)
    with patch.object(launcher.os, 'mkdir', side_effect=mkdir), \
         patch.object(launcher.time, 'sleep'):
        assert launcher.acquire_shared(lock, launcher.time.monotonic()+1, [], ['true']) is True
    assert raced[0]
    launcher.release_shared(lock)
elif mode == 'zombie-group':
    child = launcher.subprocess.Popen(['sleep', '0.1'], start_new_session=True,
                                      stdout=launcher.subprocess.PIPE)
    try:
        assert child.stdout.read() == b''
        assert launcher.owned_state(child.pid, set(), set()) == []
    finally:
        child.wait()
        child.stdout.close()
elif mode == 'proc-ownership':
    class Entry:
        def __init__(self, pid):
            self.name = str(pid)
            self.path = f'/proc/{pid}'
    class Scan:
        def __init__(self, rows):
            self.rows = rows
        def __enter__(self): return self
        def __exit__(self, *args): return False
        def __iter__(self): return iter(Entry(pid) for pid in self.rows)
    snapshots = []
    current = {}
    scans = [0]
    def scandir(path):
        assert path == '/proc'
        scans[0] += 1
        current.clear()
        current.update(snapshots[min(scans[0] - 1, len(snapshots) - 1)])
        return Scan(current)
    def stat_bytes(path):
        row = current[int(path.parent.name)]
        if isinstance(row, Exception): raise row
        state, group = row
        return f'{path.parent.name} (fixture) {state} 1 {group} 0 0 0'.encode()
    with patch.object(launcher.sys, 'platform', 'linux'), \
         patch.object(launcher.os, 'scandir', side_effect=scandir), \
         patch.object(Path, 'read_bytes', stat_bytes), \
         patch.object(launcher.os, 'killpg', return_value=None):
        # Nested corroboration must see its own job group and a registered
        # deeper group, but must never claim kernel process group zero.
        snapshots = [{2: ('S', 0), 7001: ('S', 7000), 7101: ('S', 7100)}]
        scans[0] = 0
        groups = {7100}
        rows = launcher.owned_state(7000, groups, set(), excluded=7000, query=lambda: [])
        assert sorted(rows) == [(7001, 7000), (7101, 7100)], rows
        signalled = []
        with patch.object(launcher.os, 'kill', side_effect=lambda pid, sig: signalled.append(pid)):
            launcher.signal_owned(rows, signal.SIGTERM)
        assert sorted(signalled) == [7001, 7101], signalled
        # A live root row does not justify dropping a registered group that
        # the first process listing missed.
        snapshots = [{7101: ('S', 7100)}]
        scans[0] = 0
        groups = {7100}
        assert launcher.owned_state(7000, groups, set(), query=lambda: [(7001, 7000)]) == [(7001, 7000), (7101, 7100)]
        assert groups == {7100}
        # An enumeration batch can see the zombie parent before a newly
        # reforked live child appears in the next scan.
        snapshots = [{7000: ('Z', 7000)}, {7000: ('Z', 7000), 7002: ('S', 7000)}]
        scans[0] = 0
        assert launcher.owned_state(7000, set(), set(), query=lambda: []) == [(7002, 7000)]
        assert scans[0] >= 2
        # A failed stat read cannot be mistaken for proof of absence.
        snapshots = [{7002: PermissionError(13, 'unreadable stat')}]
        scans[0] = 0
        assert launcher.owned_state(7000, set(), set(), query=lambda: []) is None
elif mode == 'eperm-signal':
    with patch.object(launcher.os, 'kill', side_effect=PermissionError(1, 'no permission')):
        launcher.signal_owned([(123456789, 123456789)], signal.SIGTERM)
else:
    raise ValueError(mode)
