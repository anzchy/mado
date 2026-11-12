#!/usr/bin/env python3
"""Kernel-owned flock lifetime, inherited by the heavy job and its descendants.

Python's standard fcntl + pass_fds make descriptor inheritance explicit on macOS.
We only close our descriptor, never LOCK_UN: unlocking the shared open-file
description would also release a surviving descendant's lock after owner death.
"""
import errno
import fcntl
import json
import math
import os
from pathlib import Path
import secrets
import select
import signal
import socket
import subprocess
import sys
import time
from array import array


MAX_DURATION_SECONDS = 1_000_000_000


def execution_budget(command):
    override = os.environ.get('PICSEE_HEAVY_LOCK_EXEC_SECS')
    if override is not None:
        value = nonnegative_env('PICSEE_HEAVY_LOCK_EXEC_SECS', override)
        if value == 0:
            raise ValueError('PICSEE_HEAVY_LOCK_EXEC_SECS must be positive')
        return value
    name = Path(command[0]).name
    args = command[1:]
    if name == 'swift' and 'test' in args:
        if '--list-tests' in args or 'list' in args:
            return 300
        if '--enable-code-coverage' in args:
            return 1800
        if '--filter' in args:
            return 600
        return 1200
    if name == 'xcodebuild' and '-list' in args:
        return 300
    return 1800


def nonnegative_env(name, default):
    value = float(os.environ.get(name, default))
    if not math.isfinite(value) or value < 0 or value > MAX_DURATION_SECONDS:
        raise ValueError(f"{name} must be a finite nonnegative number")
    return value


def process_rows():
    """Return live PID/PGID rows, or None when the query cannot prove absence."""
    if os.environ.get('PICSEE_HEAVY_FAULT_QUERY') == '1':
        return None
    try:
        query = subprocess.Popen(['ps', '-axo', 'pid=,pgid=,stat='],
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            output, _ = query.communicate(timeout=1)
        except subprocess.TimeoutExpired:
            query.kill()
            query.communicate()
            return None
        if query.returncode != 0:
            return None
        rows = []
        for line in output.splitlines():
            fields = line.split()
            if len(fields) != 3 or not fields[0].isdigit() or not fields[1].isdigit():
                return None
            if int(fields[0]) != query.pid and not fields[2].startswith('Z'):
                rows.append((int(fields[0]), int(fields[1])))
        return rows
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return None


def send_control(fd, message):
    """Register over an inherited socket and receive a private ACK endpoint."""
    try:
        control = socket.socket(fileno=os.dup(fd))
        local, reply = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            control.sendmsg([json.dumps(message).encode()],
                            [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array('i', [reply.fileno()]))])
            local.settimeout(2)
            return local.recv(256)
        finally:
            local.close()
            reply.close()
            control.close()
    except (OSError, ValueError, json.JSONDecodeError):
        return b''


def guardian_send(fd, kind, pid=0):
    if fd is None:
        return True
    try:
        os.write(fd, (json.dumps({'kind': kind, 'pid': pid}) + '\n').encode())
        return True
    except OSError:
        return False


def guardian_main(read_fd, ready_fd):
    """Hold the acquiring FD and finish cleanup if its supervisor disappears."""
    os.write(ready_fd, b'R')
    os.close(ready_fd)
    root = None
    groups = set()
    hosts = set()
    complete = False
    with os.fdopen(read_fd, 'r') as updates:
        for line in updates:
            try:
                message = json.loads(line)
                kind, pid = message['kind'], int(message['pid'])
                if kind == 'root' and pid > 0:
                    root = pid
                elif kind == 'group' and pid > 0:
                    groups.add(pid)
                elif kind == 'host' and pid > 0:
                    hosts.add(pid)
                elif kind == 'complete':
                    complete = True
                    break
            except (ValueError, KeyError, TypeError, json.JSONDecodeError):
                continue
    if complete:
        return 0
    print('[heavy-lock] guardian: supervisor disappeared; draining owned workload',
          file=sys.stderr, flush=True)
    if root is None:
        # No verifiable workload identity was published. Keep flock exclusion
        # alive for manual recovery rather than claim an empty process set.
        while True:
            time.sleep(60)
    started = time.monotonic()
    while True:
        rows = owned_state(root, groups, hosts)
        if rows == []:
            return 0
        if rows is not None:
            signal_owned(rows, signal.SIGTERM if time.monotonic() - started < 0.1 else signal.SIGKILL)
        time.sleep(0.05 if rows is not None else 1)


def receive_control(control, groups, hosts, session, guardian_fd=None, flock_required=False,
                    deadline=None, accept_groups=True):
    """Confirm registration before a nested supervisor launches its child."""
    if control is None:
        return
    while True:
        try:
            data, ancillary, _, _ = control.recvmsg(4096, socket.CMSG_SPACE(array('i').itemsize))
        except BlockingIOError:
            return
        except OSError:
            return
        if not data:
            return
        fds = array('i')
        for level, kind, payload in ancillary:
            if level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS:
                fds.frombytes(payload[:len(payload) - len(payload) % fds.itemsize])
        answer = b'NO'
        try:
            request = json.loads(data)
            kind = request.get('kind')
            pid = int(request.get('pid', 0))
            if kind == 'group' and accept_groups and deadline is not None and \
                    time.monotonic() < deadline and pid > 0 and request.get('flock') is flock_required and \
                    os.getpgid(pid) == pid and os.getsid(pid) == session:
                if guardian_send(guardian_fd, 'group', pid):
                    groups.add(pid)
                    answer = json.dumps({'status': 'OK', 'parent': os.getpid(),
                                         'deadline': deadline}).encode()
            elif kind == 'host' and pid > 0:
                os.kill(pid, 0)
                if guardian_send(guardian_fd, 'host', pid):
                    hosts.add(pid)
                    answer = b'OK'
        except (ValueError, TypeError, OSError, json.JSONDecodeError):
            pass
        for fd in fds:
            try:
                os.write(fd, answer)
            except OSError:
                pass
            finally:
                os.close(fd)


def publish_status(path, invocation, cleanup, result, timed_out):
    if not path:
        return True
    destination = Path(path)
    temporary = destination.with_name(destination.name + '.' + invocation + '.tmp')
    try:
        with os.fdopen(os.open(temporary, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600), 'w') as output:
            json.dump({'id': invocation, 'supervisor': os.getpid(), 'cleanup': cleanup,
                       'commandExit': result, 'timedOut': timed_out}, output)
            output.write('\n')
            output.flush()
            os.fsync(output.fileno())
        # A second invocation must never replace a status record that appeared
        # after preflight. Both paths are in one directory, so link is atomic.
        os.link(temporary, destination)
        temporary.unlink()
        return True
    except OSError as error:
        print(f'[heavy-lock] status publication failed: {error}', file=sys.stderr, flush=True)
        try:
            temporary.unlink(missing_ok=True)
        except OSError:
            pass
        return False


def reraise(signum):
    signal.signal(signum, signal.SIG_DFL)
    os.kill(os.getpid(), signum)
    return 128 + signum


def owner_pid(lock):
    try:
        return next((line[4:] for line in (lock / 'owner').read_text().splitlines()
                     if line.startswith('pid=')), '')
    except (FileNotFoundError, NotADirectoryError):
        return ''


def holder_desc(lock):
    try:
        return (lock / 'owner').read_text().replace('\n', ' ')
    except (FileNotFoundError, NotADirectoryError):
        return '(no owner file)'


def pid_alive(pid):
    try:
        number = int(pid)
        if number <= 0:
            return False
        os.kill(number, 0)
        return True
    except (ValueError, ProcessLookupError):
        return False
    except PermissionError:
        return True


def acquire_shared(lock, deadline, received, command):
    lock.parent.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    heartbeat = started
    first = True
    while not received:
        try:
            os.mkdir(lock)
        except FileExistsError:
            if (lock.is_symlink() or lock.exists()) and not lock.is_dir():
                print(f'[heavy-lock] mdpro lock path is not a directory: {lock}',
                      file=sys.stderr, flush=True)
                return False
        else:
            try:
                (lock / 'owner').write_text(
                    f'pid={os.getpid()}\nstarted={time.strftime("%Y-%m-%dT%H:%M:%S%z")}\n'
                    f'cwd={os.getcwd()}\ncmd={" ".join(command)}\n')
            except OSError as error:
                # A peer may reclaim the ownerless directory before publication.
                # We have no published ownership: never clean it up or launch.
                print(f'[heavy-lock] owner publication failed: {error}; waiting',
                      file=sys.stderr, flush=True)
            else:
                return True
        now = time.monotonic()
        if now >= heartbeat:
            pid = owner_pid(lock)
            if not pid or not pid_alive(pid):
                print(f'[heavy-lock] mdpro lock owner {pid or "(none)"} is dead; '
                      'waiting for an mdpro waiter to reclaim it', file=sys.stderr, flush=True)
            status = 'waiting' if first else f'still waiting ({int(now - started)}s)'
            print(f'[heavy-lock] {status} for {lock}, held by: {holder_desc(lock)}',
                  file=sys.stderr, flush=True)
            first = False
            heartbeat = now + 60
        if now >= deadline:
            print(f'[heavy-lock] lock wait timed out; held by: {holder_desc(lock)}. '
                  f'Manual recovery: first confirm no process from that job is still running '
                  f'(pgrep -f on its cmd); then remove the directory {lock}.',
                  file=sys.stderr, flush=True)
            return False
        wake = min(now + 5, deadline)
        while not received and time.monotonic() < wake:
            time.sleep(min(0.05, max(0, wake - time.monotonic())))
    return False


def release_shared(lock):
    if owner_pid(lock) == str(os.getpid()):
        (lock / 'owner').unlink()
        try:
            lock.rmdir()
        except OSError:
            pass


def owned_state(root, groups, hosts, excluded=0):
    rows = process_rows()
    if rows is None:
        return None
    live = [(pid, pgid) for pid, pgid in rows
            if pid != excluded and (pgid == root or pgid in groups or pid in hosts)]
    for pgid in tuple(groups):
        if not any(group == pgid for _, group in live):
            groups.discard(pgid)
    for pid in tuple(hosts):
        if not any(member == pid for member, _ in live):
            hosts.discard(pid)
    return live


def signal_owned(rows, sig):
    # Signal only members from one verified snapshot. A drained PGID is never
    # signalled later by number after possible reuse.
    for pid, _ in rows:
        try:
            os.kill(pid, sig)
        except ProcessLookupError:
            pass
        except PermissionError:
            pass


def stop_owned(child, root, groups, hosts, grace, control, session, excluded=0,
               guardian_fd=None, flock_required=False):
    started = time.monotonic()
    killed_at = None
    sent_term = False
    while True:
        child.poll()
        receive_control(control, groups, hosts, session, guardian_fd, flock_required,
                        accept_groups=False)
        rows = owned_state(root, groups, hosts, excluded)
        if rows == []:
            return True
        if rows is not None:
            if not sent_term:
                signal_owned(rows, signal.SIGTERM)
                sent_term = True
            if time.monotonic() - started >= grace and killed_at is None:
                killed_at = time.monotonic()
                signal_owned(rows, signal.SIGKILL)
        now = time.monotonic()
        if killed_at is None and now - started >= grace:
            killed_at = now
        if killed_at is not None and now - killed_at >= 5:
            print(f'[heavy-lock] WARNING: incomplete cleanup; survivors={rows!r}',
                  file=sys.stderr, flush=True)
            return False
        time.sleep(0.02)


def supervised_main():
    command = sys.argv[1:]
    if command[:1] == ['--guardian']:
        return guardian_main(int(command[1]), int(command[2])) if len(command) == 3 else 70
    inherited_control = os.environ.get('PICSEE_HEAVY_CONTROL_FD')
    if command[:1] == ['--register-host']:
        if len(command) != 2 or not inherited_control or not command[1].isdigit():
            return 70
        return 0 if send_control(int(inherited_control), {'kind': 'host', 'pid': int(command[1])}) == b'OK' else 70
    if not command:
        return 64
    try:
        wait_seconds = nonnegative_env('PICSEE_HEAVY_LOCK_WAIT_SECS', '1800')
        grace = nonnegative_env('PICSEE_HEAVY_LOCK_KILL_GRACE_SECS', '10')
        drain_seconds = nonnegative_env('PICSEE_HEAVY_LOCK_DRAIN_SECS', '30')
        budget = execution_budget(command)
        # Both wall-time formatting and monotonic deadline arithmetic must be
        # representable before a lock is acquired or any command is launched.
        time.localtime(time.time() + budget)
        if not math.isfinite(time.monotonic() + budget):
            raise ValueError('execution deadline is not representable')
    except (ValueError, OverflowError, OSError) as error:
        print(f'[heavy-lock] preflight refused: {error}', file=sys.stderr, flush=True)
        return 70
    held = os.environ.get('PICSEE_HEAVY_LOCK_HELD') == '1'
    ci_mode = os.environ.get('PICSEE_HEAVY_CI_TOP_LEVEL') == '1'
    nested = held and bool(inherited_control)
    if held and (nested == ci_mode):
        print('[heavy-lock] HELD needs one parent control FD or CI top-level input',
              file=sys.stderr, flush=True)
        return 70
    if ci_mode and not held:
        print('[heavy-lock] CI mode requires HELD=1', file=sys.stderr, flush=True)
        return 70
    if ci_mode and not (os.environ.get('GITHUB_ACTIONS') == 'true' or
                        os.environ.get('PICSEE_HEAVY_CI_TEST') == '1'):
        print('[heavy-lock] CI mode refused outside workflow', file=sys.stderr, flush=True)
        return 70
    inherited_flock = os.environ.get('PICSEE_HEAVY_FLOCK_FD')
    parent_deadline = None
    if nested:
        try:
            control_fd = int(inherited_control)
            os.fstat(control_fd)
            if inherited_flock:
                os.fstat(int(inherited_flock))
            os.setpgid(0, 0)
            reply = send_control(control_fd, {'kind': 'group', 'pid': os.getpid(),
                                              'flock': bool(inherited_flock)})
            handoff = json.loads(reply)
            parent_deadline = float(handoff['deadline'])
            if handoff['status'] != 'OK' or not math.isfinite(parent_deadline) or \
                    parent_deadline <= time.monotonic() or int(handoff['parent']) <= 0:
                raise ValueError('parent registration unavailable')
        except (OSError, ValueError) as error:
            print(f'[heavy-lock] nested admission refused: {error}', file=sys.stderr, flush=True)
            return 70
    status_path = os.environ.get('PICSEE_HEAVY_STATUS_PATH')
    if status_path and Path(status_path).exists():
        print('[heavy-lock] status destination already exists', file=sys.stderr, flush=True)
        return 70
    lock = Path(os.environ.get('PICSEE_HEAVY_LOCK', str(Path.home() / '.picsee/locks/heavy.lock')))
    reverse = os.environ.get('MDPRO_HEAVY_LOCK_HELD') == '1'
    shared_path = os.environ.get('PICSEE_MDPRO_LOCK', str(Path.home() / '.cache/mdpro-heavy.lock'))
    shared = None if held or reverse or shared_path == 'off' else Path(shared_path)
    fd = None
    if reverse and not held:
        print('[heavy-lock] mdpro parent already holds the shared lock; taking picsee flock only',
              file=sys.stderr, flush=True)
    if not held:
        lock.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(lock, os.O_CREAT | os.O_RDWR, 0o600)
        os.set_inheritable(fd, True)
    received = []
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, lambda number, frame: received.append(number))
    acquired = False
    retain_shared = False
    result = 70
    timed_out = False
    cleanup = 'incomplete'
    child = None
    parent_control = None
    worker_control = None
    groups = set()
    hosts = set()
    invocation = secrets.token_hex(16)
    flock_required = fd is not None or bool(inherited_flock)
    guardian = None
    guardian_write = None
    try:
        if not held:
            deadline = time.monotonic() + wait_seconds
            waiting = False
            while not received:
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except OSError as error:
                    if error.errno not in (errno.EAGAIN, errno.EACCES):
                        raise
                    if reverse:
                        print('[heavy-lock] a picsee job holds the picsee lock while waiting for mdpro\'s '
                              f'lock; picsee lock holder unknown ({lock}); reverse nesting refused',
                              file=sys.stderr, flush=True)
                        return 75
                    if not waiting:
                        print(f'[heavy-lock] waiting for {lock}', file=sys.stderr, flush=True)
                        waiting = True
                    if time.monotonic() >= deadline:
                        print(f'[heavy-lock] lock wait timed out after {wait_seconds:g}s', file=sys.stderr)
                        return 75
                    time.sleep(min(0.05, max(0, deadline - time.monotonic())))
            if not received and shared is not None:
                acquired = acquire_shared(shared, deadline, received, command)
                if not acquired and not received:
                    return 75
        if received:
            return reraise(received[0])
        if not nested:
            guardian_read, guardian_write = os.pipe()
            ready_read, ready_write = os.pipe()
            guardian_env = {**os.environ}
            guardian_env.pop('PICSEE_HEAVY_FAULT_QUERY', None)
            guardian = subprocess.Popen([sys.executable, str(Path(__file__).resolve()),
                                         '--guardian', str(guardian_read), str(ready_write)],
                                        env=guardian_env,
                                        pass_fds=(guardian_read, ready_write, fd) if fd is not None else (guardian_read, ready_write),
                                        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                        stderr=subprocess.DEVNULL)
            os.close(guardian_read)
            os.close(ready_write)
            try:
                readable, _, _ = select.select([ready_read], [], [], 2)
                if not readable or os.read(ready_read, 1) != b'R':
                    raise RuntimeError('guardian failed to become ready before launch')
            finally:
                os.close(ready_read)
        parent_control, worker_control = socket.socketpair(socket.AF_UNIX, socket.SOCK_DGRAM)
        parent_control.setblocking(False)
        child_env = {**os.environ, 'PICSEE_HEAVY_LOCK_HELD': '1',
                     'PICSEE_HEAVY_CONTROL_FD': str(worker_control.fileno())}
        child_env.pop('PICSEE_HEAVY_CI_TOP_LEVEL', None)
        child_env.pop('PICSEE_HEAVY_STATUS_PATH', None)
        if acquired:
            child_env['MDPRO_HEAVY_LOCK_HELD'] = '1'
        if fd is not None:
            child_env['PICSEE_HEAVY_FLOCK_FD'] = str(fd)
        else:
            child_env.pop('PICSEE_HEAVY_FLOCK_FD', None)
        passed = [worker_control.fileno()]
        if fd is not None:
            passed.append(fd)
        elif inherited_flock:
            passed.append(int(inherited_flock))
        launched = time.monotonic()
        execution_deadline = min(launched + budget, parent_deadline) if nested else launched + budget
        child = subprocess.Popen(command, env=child_env, pass_fds=tuple(passed),
                                 start_new_session=not nested)
        guardian_send(guardian_write, 'root', child.pid)
        worker_control.close()
        worker_control = None
        if os.environ.get('PICSEE_HEAVY_FAULT_AFTER_LAUNCH') == '1':
            ready = os.environ.get('PICSEE_HEAVY_FAULT_READY_PATH')
            if ready:
                until = time.monotonic() + 1
                while not Path(ready).exists() and time.monotonic() < until:
                    time.sleep(0.01)
            raise RuntimeError('injected post-launch supervisor exception')
        root = os.getpgrp() if nested else child.pid
        session = os.getsid(0) if nested else child.pid
        excluded = os.getpid() if nested else 0
        draining = None
        heartbeat = None
        while True:
            result = child.poll()
            receive_control(parent_control, groups, hosts, session, guardian_write, flock_required,
                            execution_deadline)
            if guardian is not None and guardian.poll() is not None:
                print('[heavy-lock] guardian disappeared before cleanup', file=sys.stderr, flush=True)
                cleanup = 'incomplete'
                break
            rows = owned_state(root, groups, hosts, excluded)
            if received:
                cleanup = 'complete' if stop_owned(child, root, groups, hosts, grace,
                                                   parent_control, session, excluded, guardian_write,
                                                   flock_required) else 'incomplete'
                break
            if time.monotonic() >= execution_deadline:
                timed_out = True
                print(f'[heavy-lock] execution timeout after {budget:g}s', file=sys.stderr, flush=True)
                cleanup = 'complete' if stop_owned(child, root, groups, hosts, grace,
                                                   parent_control, session, excluded, guardian_write,
                                                   flock_required) else 'incomplete'
                break
            if rows is None:
                if result is not None:
                    cleanup = 'incomplete'
                    print('[heavy-lock] unknown cleanup: process query failed', file=sys.stderr, flush=True)
                    break
            elif result is not None and not rows:
                cleanup = 'complete'
                break
            elif result is not None:
                now = time.monotonic()
                if draining is None:
                    draining = now
                    heartbeat = now + 5
                if now >= heartbeat:
                    print(f'[heavy-lock] job exited ({result}); waiting for group survivors: {rows}',
                          file=sys.stderr, flush=True)
                    heartbeat = now + 60
                if now - draining >= drain_seconds:
                    print('[heavy-lock] drain timed out; terminating survivors', file=sys.stderr, flush=True)
                    cleanup = 'complete' if stop_owned(child, root, groups, hosts, grace,
                                                       parent_control, session, excluded, guardian_write,
                                                       flock_required) else 'incomplete'
                    break
            time.sleep(0.02)
        retain_shared = cleanup != 'complete'
        if cleanup == 'complete':
            child.wait()
        if not publish_status(status_path, invocation, cleanup, result, timed_out):
            return 70
        if cleanup == 'complete' and guardian_write is not None:
            guardian_send(guardian_write, 'complete')
            os.close(guardian_write)
            guardian_write = None
            try:
                guardian.wait(timeout=2)
            except subprocess.TimeoutExpired:
                print('[heavy-lock] guardian did not acknowledge cleanup', file=sys.stderr, flush=True)
                return 70
            if guardian.returncode != 0:
                return 70
    except BaseException as error:
        print(f'[heavy-lock] supervisor exception: {error}', file=sys.stderr, flush=True)
        if child is not None:
            retain_shared = True
            try:
                root = os.getpgrp() if nested else child.pid
                session = os.getsid(0) if nested else child.pid
                cleanup = 'complete' if stop_owned(child, root, groups, hosts, grace,
                                                   parent_control, session, os.getpid() if nested else 0,
                                                   guardian_write, flock_required) else 'incomplete'
                retain_shared = cleanup != 'complete'
                publish_status(status_path, invocation, cleanup, child.poll(), False)
            except BaseException as cleanup_error:
                print(f'[heavy-lock] cleanup unknown after exception: {cleanup_error}',
                      file=sys.stderr, flush=True)
        return 70
    finally:
        if worker_control is not None:
            worker_control.close()
        if parent_control is not None:
            parent_control.close()
        if guardian_write is not None:
            if child is None:
                guardian_send(guardian_write, 'complete')
            os.close(guardian_write)
        if acquired and not retain_shared:
            release_shared(shared)
        if fd is not None:
            os.close(fd)
    if cleanup != 'complete':
        return 70
    if timed_out:
        return 124
    if received:
        return reraise(received[0])
    if result is None:
        return 70
    if result < 0:
        return reraise(-result)
    return result


if __name__ == '__main__':
    sys.exit(supervised_main())
