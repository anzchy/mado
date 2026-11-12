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
lock = Path(os.environ['PICSEE_MDPRO_LOCK'])

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
elif mode == 'eperm-signal':
    with patch.object(launcher.os, 'kill', side_effect=PermissionError(1, 'no permission')):
        launcher.signal_owned([(123456789, 123456789)], signal.SIGTERM)
else:
    raise ValueError(mode)
