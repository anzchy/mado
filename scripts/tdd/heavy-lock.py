#!/usr/bin/env python3
"""Kernel-owned flock lifetime, held by the supervisor and its guardian.

Jobs receive a registration socket, not the flock descriptor. A nested heavy-lock
supervisor receives a duplicate descriptor only after registration. Never LOCK_UN:
unlocking the shared open-file description would release another owner's guard.
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
import stat
import subprocess
import sys
import time
from array import array


MAX_DURATION_SECONDS = 1_000_000_000


def execution_budget(command):
    override = os.environ.get('MADO_HEAVY_LOCK_EXEC_SECS')
    if override is not None:
        value = nonnegative_env('MADO_HEAVY_LOCK_EXEC_SECS', override)
        if value == 0:
            raise ValueError('MADO_HEAVY_LOCK_EXEC_SECS must be positive')
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


def safe_job_name(command):
    """A useful diagnostic identifier that contains no command text."""
    return f'argc={len(command)}'


def process_rows(command=None):
    """Return live PID/PGID rows, or None when the query cannot prove absence.

    `command` replaces /bin/ps only for the exit-query test plan (exit_query)."""
    if os.environ.get('MADO_HEAVY_FAULT_QUERY') == '1':
        return None
    try:
        # Absolute path (#705 T3): the job's PATH must not choose the program
        # that decides whether owned members still exist.
        query = subprocess.Popen(command or ['/bin/ps', '-axo', 'pid=,pgid=,stat='],
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


class QueryRetry:
    """Bounded retry of the process query after the job's leader exits (#705 T5).

    One failed `ps` (a timeout under load, a malformed line) used to end the run
    as unknown cleanup although the next query would have answered. A failure
    starts a streak: the next query waits `interval` after the last failure, and
    the streak is exhausted after `attempts` failures or `budget` seconds from
    its first failure, whichever comes first. Exhausted stays exhausted until a
    query succeeds. Any successful snapshot, empty or not, ends the streak; the
    caller decides what the rows mean (release only on an empty one)."""

    def __init__(self, attempts=4, interval=0.2, budget=5.0, clock=time.monotonic):
        self.attempts, self.interval, self.budget, self.clock = attempts, interval, budget, clock
        self.failures = []
        self.exhausted = False

    @staticmethod
    def _since(now, then):
        # Elapsed time at 1 us: on a float clock 0.6 - 0.4 is just under 0.2.
        return round(now - then, 6)

    def _expired(self, now):
        return bool(self.failures) and (len(self.failures) >= self.attempts
                                        or self._since(now, self.failures[0]) >= self.budget)

    def next_action(self):
        """'query' when a query may run now, 'wait' between attempts, or 'exhausted'."""
        now = self.clock()
        if self.exhausted or self._expired(now):
            self.exhausted = True
            return 'exhausted'
        if self.failures and self._since(now, self.failures[-1]) < self.interval:
            return 'wait'
        return 'query'

    def observe(self, rows):
        """Record a query result (None is a failure): 'ok', 'wait' or 'exhausted'."""
        now = self.clock()
        if rows is not None:
            self.failures = []
            self.exhausted = False
            return 'ok'
        if self.exhausted:
            return 'exhausted'
        self.failures.append(now)
        if self._expired(now):
            self.exhausted = True
            return 'exhausted'
        return 'wait'


# Test seam for the post-exit query only (#705 T5). The plan file lists tokens
# (comma or whitespace separated); each post-exit query consumes one, appends
# "<token> <monotonic>" to <plan>.log and runs a real substitute. An unknown
# token is a failing query; an exhausted plan runs the real query. The variable
# is removed from the guardian's and the job's environment.
EXIT_QUERY_SUBSTITUTES = {'error': ['/usr/bin/false'], 'timeout': ['/bin/sleep', '5'],
                          'malformed': ['/bin/echo', 'garbage']}
exit_query_plan = {'tokens': None, 'next': 0}


def exit_query():
    """The process query used after the leader exits."""
    plan = os.environ.get('MADO_HEAVY_FAULT_EXIT_QUERY_PLAN')
    if not plan:
        return process_rows()
    if exit_query_plan['tokens'] is None:
        try:
            exit_query_plan['tokens'] = Path(plan).read_text().replace(',', ' ').split()
        except OSError:
            exit_query_plan['tokens'] = []
    tokens = exit_query_plan['tokens']
    if exit_query_plan['next'] >= len(tokens):
        return process_rows()
    token = tokens[exit_query_plan['next']]
    exit_query_plan['next'] += 1
    try:
        with open(f'{plan}.log', 'a') as log:
            log.write(f'{token} {time.monotonic()}\n')
    except OSError:
        pass
    if token == 'real':
        return process_rows()
    return process_rows(EXIT_QUERY_SUBSTITUTES.get(token, ['/usr/bin/false']))


def send_control(fd, message, expect_fd=False):
    """Register over an inherited socket and receive a private ACK and optional FD."""
    try:
        control = socket.socket(fileno=os.dup(fd))
        local, reply = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            control.sendmsg([json.dumps(message).encode()],
                            [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array('i', [reply.fileno()]))])
            local.settimeout(2)
            if not expect_fd:
                return local.recv(256)
            data, ancillary, _, _ = local.recvmsg(256, socket.CMSG_SPACE(array('i').itemsize))
            received = array('i')
            for level, kind, payload in ancillary:
                if level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS:
                    received.frombytes(payload[:len(payload) - len(payload) % received.itemsize])
            for extra in received[1:]:
                os.close(extra)
            return data, (received[0] if received else None)
        finally:
            local.close()
            reply.close()
            control.close()
    except (OSError, ValueError, json.JSONDecodeError):
        return (b'', None) if expect_fd else b''


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
    for caught in (signal.SIGINT, signal.SIGHUP, signal.SIGTERM):
        signal.signal(caught, signal.SIG_IGN)
    owner_path = os.environ.get('MADO_HEAVY_GUARDIAN_OWNER')
    if owner_path:
        argc = os.environ.get('MADO_HEAVY_GUARDIAN_ARGC', '')
        job = f'argc={argc}' if argc.isdecimal() else 'unknown'
        with os.fdopen(os.open(owner_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600), 'w') as owner:
            owner.write(f'pid={os.getpid()}\n'
                        f'cmd={sys.executable} {Path(__file__).resolve()} --guardian {read_fd} {ready_fd}\n'
                        f'started={time.strftime("%Y-%m-%dT%H:%M:%S%z")}\n'
                        f'startedEpoch={time.time():.6f}\n'
                        f'budgetSeconds={os.environ.get("MADO_HEAVY_GUARDIAN_BUDGET", "unknown")}\n'
                        f'supervisor={os.environ.get("MADO_HEAVY_GUARDIAN_SUPERVISOR", "unknown")}\n'
                        f'job={job}\n')
    os.write(ready_fd, b'R')
    os.close(ready_fd)
    root = None
    groups = set()
    hosts = set()
    unknown = False
    complete = False
    # Before root publication the supervisor is the only holder that can
    # launch work. Bound that handoff even if the pipe remains open forever.
    publish_deadline = time.monotonic() + 2
    pending = b''
    while True:
        if root is None:
            remaining = publish_deadline - time.monotonic()
            if remaining <= 0:
                print('[heavy-lock] guardian: root was never published before deadline',
                      file=sys.stderr, flush=True)
                return 0
            readable, _, _ = select.select([read_fd], [], [], remaining)
            if not readable:
                continue
        chunk = os.read(read_fd, 4096)
        if not chunk:
            break
        pending += chunk
        while b'\n' in pending:
            line, pending = pending.split(b'\n', 1)
            try:
                message = json.loads(line)
                kind, pid = message['kind'], int(message['pid'])
                if kind == 'root' and pid > 0:
                    if root != pid and owner_path:
                        with open(owner_path, 'a') as owner:
                            owner.write(f'child={pid}\n')
                    root = pid
                elif kind == 'group' and pid > 0:
                    if pid not in groups and owner_path:
                        with open(owner_path, 'a') as owner:
                            owner.write(f'group={pid}\n')
                    groups.add(pid)
                elif kind == 'host' and pid > 0:
                    hosts.add(pid)
                elif kind == 'host-unknown':
                    unknown = True
                elif kind == 'complete':
                    complete = True
                    break
            except (ValueError, KeyError, TypeError, json.JSONDecodeError):
                continue
        if complete:
            break
    if complete:
        return 0
    print('[heavy-lock] guardian: supervisor disappeared; draining owned workload',
          file=sys.stderr, flush=True)
    if root is None:
        print('[heavy-lock] guardian: root was never published; no workload launched',
              file=sys.stderr, flush=True)
        return 0
    started = time.monotonic()
    while True:
        rows = owned_state(root, groups, hosts)
        if rows == []:
            return 0
        if rows is not None:
            signal_owned(rows, signal.SIGTERM if time.monotonic() - started < 0.1 else signal.SIGKILL)
        time.sleep(0.05 if rows is not None else 1)


def receive_control(control, groups, hosts, session, guardian_fd=None, flock_required=False,
                    deadline=None, accept_groups=True, ancestor_control_fd=None,
                    shared_owned=False, unknown=None, flock_fd=None):
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
        grant_flock = False
        try:
            request = json.loads(data)
            kind = request.get('kind')
            pid = int(request.get('pid', 0))
            if kind == 'group' and accept_groups and deadline is not None and \
                    time.monotonic() < deadline and pid > 0 and request.get('flock') is flock_required and \
                    os.getpgid(pid) == pid and os.getsid(pid) == session:
                forwarded = True
                if ancestor_control_fd is not None:
                    upstream, duplicate = send_control(ancestor_control_fd, request, expect_fd=True)
                    if duplicate is not None:
                        os.close(duplicate)
                    forwarded = json.loads(upstream).get('status') == 'OK'
                if forwarded and guardian_send(guardian_fd, 'group', pid):
                    groups.add(pid)
                    answer = json.dumps({'status': 'OK', 'parent': os.getpid(),
                                         'deadline': deadline, 'shared': shared_owned}).encode()
                    grant_flock = flock_required
            elif kind == 'host' and pid > 0:
                os.kill(pid, 0)
                forwarded = ancestor_control_fd is None or send_control(ancestor_control_fd, request) == b'OK'
                if forwarded and guardian_send(guardian_fd, 'host', pid):
                    hosts.add(pid)
                    answer = b'OK'
            elif kind == 'host-unknown':
                if unknown is not None:
                    unknown[0] = True
                forwarded = ancestor_control_fd is None or send_control(ancestor_control_fd, request) == b'OK'
                if forwarded and guardian_send(guardian_fd, 'host-unknown'):
                    answer = b'OK'
        except (ValueError, TypeError, OSError, json.JSONDecodeError):
            pass
        for fd in fds:
            try:
                if grant_flock and flock_fd is not None:
                    endpoint = socket.socket(fileno=os.dup(fd))
                    try:
                        endpoint.sendmsg([answer], [(socket.SOL_SOCKET, socket.SCM_RIGHTS,
                                                      array('i', [flock_fd]))])
                    finally:
                        endpoint.close()
                else:
                    os.write(fd, answer)
            except OSError:
                pass
            finally:
                os.close(fd)


def publish_status(path, invocation, cleanup, result, timed_out, drain_expired=False):
    if not path:
        return True
    destination = Path(path)
    temporary = destination.with_name(destination.name + '.' + invocation + '.tmp')
    try:
        if os.environ.get('MADO_HEAVY_FAULT_STATUS_WRITE') == '1':
            raise OSError('injected status publication failure')
        with os.fdopen(os.open(temporary, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600), 'w') as output:
            json.dump({'id': invocation, 'supervisor': os.getpid(), 'cleanup': cleanup,
                       'commandExit': result, 'timedOut': timed_out,
                       'drainExpired': drain_expired}, output)
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


def wall_time(seconds):
    return time.strftime('%Y-%m-%dT%H:%M:%S%z', time.localtime(seconds))


def survivor_details(rows):
    """PID/PGID/state/RSS for owned rows, or None when the state cannot be read."""
    if rows is None:
        return None
    if not rows:
        return []
    try:
        query = subprocess.run(['/bin/ps', '-o', 'pid=,pgid=,stat=,rss=', '-p', ','.join(str(pid) for pid, _ in rows)],
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=2)
    except (OSError, subprocess.TimeoutExpired):
        return None
    details = []
    for line in query.stdout.splitlines():
        fields = line.split()
        if len(fields) == 4 and fields[0].isdigit() and fields[1].isdigit() and fields[3].isdigit():
            details.append({'pid': int(fields[0]), 'pgid': int(fields[1]),
                            'state': fields[2], 'rssKiB': int(fields[3])})
    return details


class LockAlert:
    """#672: tell the delegator, through its status loop, that a holder exceeded its budget.

    Writes ~/.mado/herdr/delegator/lock-alerts/<invocation>.json (0600) and appends one
    line to attention.log beside it; `listen-notify.py status` reports open alerts as
    attention. MADO_HEAVY_ALERT_DIR overrides the delegator directory. Without it, only
    the machine lock (~/.mado/locks/heavy.lock) alerts: test fixtures on private lock
    files time out on purpose and must not reach the real attention channel. Alert failures
    are reported on stderr and never change the job's result.
    """

    @staticmethod
    def directory_for(lock, fd):
        chosen = os.environ.get('MADO_HEAVY_ALERT_DIR')
        if chosen:
            return Path(chosen)
        machine = Path.home() / '.mado/locks/heavy.lock'
        if fd is not None and os.path.abspath(lock) == os.path.abspath(machine):
            return Path.home() / '.mado/herdr/delegator'
        return None

    def __init__(self, record, base):
        self.record = record
        self.directory = base / 'lock-alerts'
        self.path = self.directory / f"{record['id']}.json"
        self.log = base / 'attention.log'

    def publish(self, first):
        try:
            self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
            temporary = self.path.with_name(self.path.name + '.tmp')
            with os.fdopen(os.open(temporary, os.O_CREAT | os.O_TRUNC | os.O_WRONLY, 0o600), 'w') as output:
                json.dump(self.record, output, indent=2)
                output.write('\n')
            os.replace(temporary, self.path)
            if first:
                record = self.record
                with self.log.open('a') as log:
                    log.write(f"{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())} heavy-lock holder exceeded "
                              f"its {record['budgetSeconds']:g}s budget; pid {record['pid']} pgid {record['pgid']}; "
                              f"alert {self.path}; run listen-notify.py status\n")
            print(f'[heavy-lock] lock-age alert: {self.path}', file=sys.stderr, flush=True)
        except OSError as error:
            print(f'[heavy-lock] lock-age alert failed: {error}', file=sys.stderr, flush=True)


def reraise(signum):
    # SIGKILL and SIGSTOP have no settable disposition: signal.signal raises
    # OSError(EINVAL), which turned a job killed by SIGKILL (jetsam, kill -9) into
    # a traceback and exit 1, an ordinary test failure to every lane (#705 T2).
    # Report the shell's 128+signal status instead of re-raising.
    if signum in (signal.SIGKILL, signal.SIGSTOP):
        return 128 + signum
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


def lock_status(lock):
    """Report live guardian records without waiting for or acquiring either lock."""
    holders = []
    rows = process_rows()
    for record in sorted(lock.parent.glob('heavy.lock.guardian-*.owner')):
        try:
            lines = record.read_text().splitlines()
            fields = dict(line.split('=', 1) for line in lines if '=' in line)
            holder = int(fields['pid'])
            wrapper = int(fields['supervisor'])
            if holder <= 0 or not pid_alive(holder):
                continue
            root = int(fields.get('child', '0'))
            groups = {int(line[6:]) for line in lines if line.startswith('group=')}
            owned_groups = ({root} if root > 0 else set()) | {group for group in groups if group > 0}
            started = float(fields['startedEpoch'])
            budget = float(fields['budgetSeconds'])
            age = max(0, time.time() - started)
            children = sorted(pid for pid, pgid in (rows or [])
                              if pid in owned_groups or pgid in owned_groups)
            wrapper_live = pid_alive(wrapper)
            holders.append({'holderPid': holder, 'wrapperPid': wrapper,
                            'wrapperAlive': wrapper_live, 'childPids': children,
                            'ageSeconds': round(age, 3), 'budgetSeconds': budget,
                            'orphanOverBudget': not wrapper_live and bool(children) and age > budget})
        except (OSError, ValueError, KeyError, OverflowError):
            continue
    return {'lock': str(lock), 'holders': holders, 'processQuery': 'ok' if rows is not None else 'unknown'}


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
                    f'cwd={os.getcwd()}\ncmd={safe_job_name(command)}\n')
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
                  f'(inspect the owner PID and its process group); then remove the directory {lock}.',
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


def owned_state(root, groups, hosts, excluded=0, query=process_rows):
    rows = query()
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
               guardian_fd=None, flock_required=False, ancestor_control_fd=None, unknown=None):
    started = time.monotonic()
    killed_at = None
    sent_term = False
    while True:
        child.poll()
        receive_control(control, groups, hosts, session, guardian_fd, flock_required,
                        accept_groups=False, ancestor_control_fd=ancestor_control_fd,
                        unknown=unknown)
        rows = owned_state(root, groups, hosts, excluded)
        if rows == []:
            return True
        if rows is not None:
            if not sent_term:
                signal_owned(rows, signal.SIGTERM)
                sent_term = True
            if time.monotonic() - started >= grace:
                # After the grace, KILL every member of each fresh snapshot
                # (#705 T1). A single KILL misses members forked between that
                # snapshot and their parent's death; they appear only in a later
                # one. The 5 s window below still bounds an unkillable group.
                if killed_at is None:
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
    if command in (['status'], ['--status']):
        lock = Path(os.environ.get('MADO_HEAVY_LOCK', str(Path.home() / '.mado/locks/heavy.lock')))
        print(json.dumps(lock_status(lock), sort_keys=True))
        return 0
    inherited_control = os.environ.get('MADO_HEAVY_CONTROL_FD')
    if command[:1] == ['--register-host']:
        if len(command) != 2 or not inherited_control or not command[1].isdigit():
            print('[heavy-lock] host registration refused: invalid PID or missing control FD', file=sys.stderr, flush=True)
            return 70
        reply = send_control(int(inherited_control), {'kind': 'host', 'pid': int(command[1])})
        if reply != b'OK':
            print(f'[heavy-lock] host registration refused: parent reply {reply!r}', file=sys.stderr, flush=True)
            return 70
        return 0
    if command == ['--mark-host-unknown']:
        if not inherited_control:
            return 70
        return 0 if send_control(int(inherited_control), {'kind': 'host-unknown'}) == b'OK' else 70
    if not command:
        return 64
    try:
        wait_seconds = nonnegative_env('MADO_HEAVY_LOCK_WAIT_SECS', '1800')
        grace = nonnegative_env('MADO_HEAVY_LOCK_KILL_GRACE_SECS', '10')
        drain_seconds = nonnegative_env('MADO_HEAVY_LOCK_DRAIN_SECS', '30')
        budget = execution_budget(command)
        # Both wall-time formatting and monotonic deadline arithmetic must be
        # representable before a lock is acquired or any command is launched.
        time.localtime(time.time() + budget)
        if not math.isfinite(time.monotonic() + budget):
            raise ValueError('execution deadline is not representable')
    except (ValueError, OverflowError, OSError) as error:
        print(f'[heavy-lock] preflight refused: {error}', file=sys.stderr, flush=True)
        return 70
    held = os.environ.get('MADO_HEAVY_LOCK_HELD') == '1'
    ci_mode = os.environ.get('MADO_HEAVY_CI_TOP_LEVEL') == '1'
    nested = held and bool(inherited_control)
    if held and (nested == ci_mode):
        print('[heavy-lock] HELD needs one parent control FD or CI top-level input',
              file=sys.stderr, flush=True)
        return 70
    if ci_mode and not held:
        print('[heavy-lock] CI mode requires HELD=1', file=sys.stderr, flush=True)
        return 70
    if ci_mode and not (os.environ.get('GITHUB_ACTIONS') == 'true' or
                        os.environ.get('MADO_HEAVY_CI_TEST') == '1'):
        print('[heavy-lock] CI mode refused outside workflow', file=sys.stderr, flush=True)
        return 70
    inherited_flock = os.environ.get('MADO_HEAVY_FLOCK_FD')
    expected_flock = os.environ.get('MADO_HEAVY_FLOCK_EXPECTED') == '1'
    received_flock = None
    parent_deadline = None
    parent_shared = False
    ancestor_control_fd = None
    if nested:
        try:
            control_fd = int(inherited_control)
            ancestor_control_fd = control_fd
            os.fstat(control_fd)
            if inherited_flock:
                os.fstat(int(inherited_flock))
            os.setpgid(0, 0)
            reply, received_flock = send_control(control_fd, {'kind': 'group', 'pid': os.getpid(),
                'flock': bool(inherited_flock) or expected_flock}, expect_fd=True)
            try:
                handoff = json.loads(reply)
            except (ValueError, TypeError) as error:
                raise ValueError(f'parent registration unavailable ({reply!r})') from error
            parent_deadline = float(handoff['deadline'])
            if handoff['status'] != 'OK' or not math.isfinite(parent_deadline) or \
                    parent_deadline <= time.monotonic() or int(handoff['parent']) <= 0:
                raise ValueError('parent registration unavailable')
            if expected_flock and received_flock is None:
                raise ValueError('parent did not transfer the required flock descriptor')
            if received_flock is not None:
                if inherited_flock:
                    os.close(received_flock)
                    received_flock = None
                else:
                    inherited_flock = str(received_flock)
                    os.fstat(received_flock)
            parent_shared = handoff.get('shared') is True
        except (OSError, ValueError) as error:
            if received_flock is not None:
                os.close(received_flock)
            print(f'[heavy-lock] nested admission refused: {error}', file=sys.stderr, flush=True)
            return 70
    status_path = os.environ.get('MADO_HEAVY_STATUS_PATH')
    private_fd_text = os.environ.get('MADO_HEAVY_ATTEST_FD')
    private_fd = None
    if private_fd_text or os.environ.get('MADO_HEAVY_STATUS_DIR'):
        try:
            if not private_fd_text or status_path or os.environ.get('MADO_HEAVY_STATUS_DIR'):
                raise ValueError('invalid private status channel')
            private_fd = int(private_fd_text)
            if private_fd < 3 or private_fd in [int(inherited_control or -1),
                                               int(inherited_flock or -1)]:
                raise ValueError('private status FD must be separate from stdio and control')
            mode = os.fstat(private_fd).st_mode
            if not (stat.S_ISFIFO(mode) or stat.S_ISSOCK(mode)):
                raise ValueError('private status FD must be a pipe or socket')
        except (OSError, ValueError) as error:
            print(f'[heavy-lock] private status refused: {error}', file=sys.stderr, flush=True)
            return 70
    if status_path and Path(status_path).exists():
        print('[heavy-lock] status destination already exists', file=sys.stderr, flush=True)
        return 70
    lock = Path(os.environ.get('MADO_HEAVY_LOCK', str(Path.home() / '.mado/locks/heavy.lock')))
    reverse = os.environ.get('MDPRO_HEAVY_LOCK_HELD') == '1'
    if reverse and not parent_shared:
        print('[heavy-lock] reverse mdpro nesting refused: no verified handoff (#665)',
              file=sys.stderr, flush=True)
        return 70
    shared_path = os.environ.get('MADO_MDPRO_LOCK', str(Path.home() / '.cache/mdpro-heavy.lock'))
    shared = None if held or reverse or shared_path == 'off' else Path(shared_path)
    fd = None
    if not held:
        lock.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(lock, os.O_CREAT | os.O_RDWR, 0o600)
        os.set_inheritable(fd, False)
    received = []
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, lambda number, frame: received.append(number))
    acquired = False
    retain_shared = False
    result = 70
    timed_out = False
    drain_expired = False
    guardian_lost = False
    cleanup = 'incomplete'
    child = None
    parent_control = None
    worker_control = None
    groups = set()
    hosts = set()
    unknown = [False]
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
            guardian_env.pop('MADO_HEAVY_FAULT_QUERY', None)
            guardian_env.pop('MADO_HEAVY_FAULT_EXIT_QUERY_PLAN', None)
            guardian_owner = lock.parent / f'heavy.lock.guardian-{invocation}.owner'
            guardian_log = lock.parent / f'heavy.lock.guardian-{invocation}.log'
            guardian_env['MADO_HEAVY_GUARDIAN_OWNER'] = str(guardian_owner)
            guardian_env['MADO_HEAVY_GUARDIAN_SUPERVISOR'] = str(os.getpid())
            guardian_env['MADO_HEAVY_GUARDIAN_ARGC'] = str(len(command))
            guardian_env['MADO_HEAVY_GUARDIAN_BUDGET'] = str(budget)
            lock.parent.mkdir(parents=True, exist_ok=True)
            with os.fdopen(os.open(guardian_log, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600),
                           'wb', buffering=0) as guardian_error:
                guardian = subprocess.Popen([sys.executable, str(Path(__file__).resolve()),
                                             '--guardian', str(guardian_read), str(ready_write)],
                                            env=guardian_env,
                                            pass_fds=(guardian_read, ready_write, fd) if fd is not None else (guardian_read, ready_write),
                                            start_new_session=True,
                                            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                            stderr=guardian_error)
            os.close(guardian_read)
            os.close(ready_write)
            try:
                readable, _, _ = select.select([ready_read], [], [], 2)
                if not readable or os.read(ready_read, 1) != b'R':
                    raise RuntimeError('guardian failed to become ready before launch')
            finally:
                os.close(ready_read)
        if private_fd is not None:
            header = (json.dumps({'kind': 'begin', 'id': invocation,
                                  'supervisor': os.getpid()}) + '\n').encode()
            if len(header) > os.fpathconf(private_fd, 'PC_PIPE_BUF') or \
                    os.write(private_fd, header) != len(header):
                raise OSError('private status header publication failed')
        parent_control, worker_control = socket.socketpair(socket.AF_UNIX, socket.SOCK_DGRAM)
        parent_control.setblocking(False)
        child_env = {**os.environ, 'MADO_HEAVY_LOCK_HELD': '1',
                     'MADO_HEAVY_CONTROL_FD': str(worker_control.fileno())}
        child_env.pop('MADO_HEAVY_CI_TOP_LEVEL', None)
        child_env.pop('MADO_HEAVY_STATUS_PATH', None)
        child_env.pop('MADO_HEAVY_STATUS_DIR', None)
        child_env.pop('MADO_HEAVY_ATTEST_FD', None)
        child_env.pop('MADO_HEAVY_FAULT_STATUS_WRITE', None)
        child_env.pop('MADO_HEAVY_FAULT_EXIT_QUERY_PLAN', None)
        if acquired:
            child_env['MDPRO_HEAVY_LOCK_HELD'] = '1'
        child_env.pop('MADO_HEAVY_FLOCK_FD', None)
        child_env['MADO_HEAVY_FLOCK_EXPECTED'] = '1' if flock_required else '0'
        passed = [worker_control.fileno()]
        if guardian_write is not None:
            passed.append(guardian_write)
        launched = time.monotonic()
        launched_wall = time.time()
        execution_deadline = min(launched + budget, parent_deadline) if nested else launched + budget
        def publish_root_before_exec():
            # A supervisor killed during Popen cannot strand an unidentified
            # worker. This child writes its own PID before exec, then closes
            # the guardian pipe so parent death still triggers cleanup.
            if not guardian_send(guardian_write, 'root', os.getpid()):
                os._exit(70)
            os.close(guardian_write)
        child = subprocess.Popen(command, env=child_env, pass_fds=tuple(passed),
                                 start_new_session=not nested,
                                 preexec_fn=publish_root_before_exec if guardian_write is not None else None)
        guardian_send(guardian_write, 'root', child.pid)
        worker_control.close()
        worker_control = None
        if os.environ.get('MADO_HEAVY_FAULT_AFTER_LAUNCH') == '1':
            ready = os.environ.get('MADO_HEAVY_FAULT_READY_PATH')
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
        exit_retry = QueryRetry()
        query_state = None
        while True:
            result = child.poll()
            receive_control(parent_control, groups, hosts, session, guardian_write, flock_required,
                            execution_deadline, ancestor_control_fd=ancestor_control_fd,
                            shared_owned=acquired or parent_shared, unknown=unknown,
                            flock_fd=fd if fd is not None else int(inherited_flock) if inherited_flock else None)
            if guardian is not None and guardian.poll() is not None:
                guardian_lost = True
                print('[heavy-lock] guardian disappeared before cleanup', file=sys.stderr, flush=True)
                cleanup = 'complete' if stop_owned(child, root, groups, hosts, grace,
                                                   parent_control, session, excluded, guardian_write,
                                                   flock_required, ancestor_control_fd, unknown) else 'incomplete'
                break
            if result is None:
                rows = owned_state(root, groups, hosts, excluded)
            elif received:
                rows = None  # the stop below runs its own queries
            else:
                # After the leader exits, a failed query is retried within
                # QueryRetry's bounds; cancellation, registration and the
                # execution deadline are still handled on every pass.
                query_state = exit_retry.next_action()
                rows = None
                if query_state == 'query':
                    rows = owned_state(root, groups, hosts, excluded, query=exit_query)
                    query_state = exit_retry.observe(rows)
            if received:
                cleanup = 'complete' if stop_owned(child, root, groups, hosts, grace,
                                                   parent_control, session, excluded, guardian_write,
                                                   flock_required, ancestor_control_fd, unknown) else 'incomplete'
                break
            if time.monotonic() >= execution_deadline:
                timed_out = True
                print(f'[heavy-lock] execution timeout after {budget:g}s', file=sys.stderr, flush=True)
                alert = None
                alert_dir = None if nested else LockAlert.directory_for(lock, fd)
                if alert_dir is not None:
                    alert = LockAlert({
                        'kind': 'heavy-lock-budget-exceeded', 'id': invocation, 'phase': 'deadline',
                        'command': command, 'cwd': os.getcwd(), 'budgetSeconds': budget,
                        'startedAt': wall_time(launched_wall), 'deadlineAt': wall_time(launched_wall + budget),
                        'exceededAt': wall_time(time.time()), 'supervisor': os.getpid(), 'pid': child.pid,
                        'pgid': root, 'groups': sorted(groups), 'hosts': sorted(hosts),
                        'survivorsAtDeadline': survivor_details(rows), 'cleanup': None,
                        'survivorsAfterCleanup': None, 'retainedLocks': None}, alert_dir)
                    alert.publish(first=True)
                cleanup = 'complete' if stop_owned(child, root, groups, hosts, grace,
                                                   parent_control, session, excluded, guardian_write,
                                                   flock_required, ancestor_control_fd, unknown) else 'incomplete'
                if alert is not None:
                    retained = cleanup != 'complete' or unknown[0]
                    after = [] if cleanup == 'complete' else survivor_details(owned_state(root, groups, hosts, excluded))
                    alert.record.update({
                        'phase': 'cleanup', 'cleanup': cleanup, 'survivorsAfterCleanup': after,
                        'retainedLocks': ([{'kind': 'picsee-flock', 'path': str(lock), 'retained': retained}] if fd is not None else []) +
                                         ([{'kind': 'mdpro-directory', 'path': str(shared), 'retained': retained}] if acquired else [])})
                    alert.publish(first=False)
                break
            if rows is None:
                if result is not None and query_state == 'exhausted':
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
            # The drain runs from the first snapshot with survivors; a failed
            # query in between neither resets nor pauses it.
            if draining is not None and time.monotonic() - draining >= drain_seconds:
                print('[heavy-lock] drain timed out; terminating survivors', file=sys.stderr, flush=True)
                drain_expired = True
                cleanup = 'complete' if stop_owned(child, root, groups, hosts, grace,
                                                   parent_control, session, excluded, guardian_write,
                                                   flock_required, ancestor_control_fd, unknown) else 'incomplete'
                break
            time.sleep(0.02)
        known_cleanup = cleanup
        if unknown[0]:
            cleanup = 'incomplete'
        retain_shared = known_cleanup != 'complete'
        if known_cleanup == 'complete':
            child.wait()
        if not publish_status(status_path, invocation, cleanup, result, timed_out, drain_expired):
            return 70
        if private_fd is not None:
            try:
                if os.environ.get('MADO_HEAVY_FAULT_STATUS_WRITE') == '1':
                    raise OSError('injected status publication failure')
                record = (json.dumps({'kind': 'status', 'id': invocation,
                                      'supervisor': os.getpid(), 'cleanup': cleanup,
                                      'commandExit': result, 'timedOut': timed_out,
                                      'drainExpired': drain_expired}) + '\n').encode()
                if len(record) > os.fpathconf(private_fd, 'PC_PIPE_BUF') or \
                        os.write(private_fd, record) != len(record):
                    raise OSError('short private status record')
            except OSError as error:
                print(f'[heavy-lock] private status publication failed: {error}', file=sys.stderr, flush=True)
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
            try:
                guardian_owner.unlink(missing_ok=True)
                guardian_log.unlink(missing_ok=True)
            except OSError as error:
                print(f'[heavy-lock] diagnostic cleanup failed: {error}',
                      file=sys.stderr, flush=True)
    except BaseException as error:
        print(f'[heavy-lock] supervisor exception: {error}', file=sys.stderr, flush=True)
        if child is not None:
            retain_shared = True
            try:
                root = os.getpgrp() if nested else child.pid
                session = os.getsid(0) if nested else child.pid
                cleanup = 'complete' if stop_owned(child, root, groups, hosts, grace,
                                                   parent_control, session, os.getpid() if nested else 0,
                                                   guardian_write, flock_required, ancestor_control_fd, unknown) else 'incomplete'
                known_cleanup = cleanup
                if unknown[0]:
                    cleanup = 'incomplete'
                retain_shared = known_cleanup != 'complete'
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
        if received_flock is not None:
            os.close(received_flock)
    if cleanup != 'complete':
        return 70
    if guardian_lost:
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
