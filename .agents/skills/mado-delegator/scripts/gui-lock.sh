#!/bin/zsh
# gui-lock.sh acquire|wait|release|status — the machine-wide desktop GUI lock shared with mdpro
# (mdpro ADR-0141 WI-2 and docs/reference/20261027-desktop-gui-lock-agreement-with-picsee.md; port of mdpro's
# .agents/skills/mdpro-delegator/scripts/gui-lock.sh, which is the reference — keep the two in step).
#
#   mutex    : $HOME/.cache/desktop-gui.mutex — a permanent BSD flock(2) file, never deleted. Every acquire and
#              release does its read-check-mutate while holding it.
#   lock dir : $HOME/.cache/desktop-gui.lock/ — created by acquire, removed only by its own release, never renamed.
#   owner    : exactly eight key=value lines, published 0600 with O_EXCL|O_NOFOLLOW:
#              project=picsee session batch=<run-id> start pid expected_minutes purpose acquisition_id=<uuid4>
#
# Take it before the FIRST GUI-driving action of a device run (launch, panels, keys, mouse, drags, screencapture,
# app activation) and hold it across relaunch sub-runs; release only after the app has quit (after cleanup), also on
# aborted runs. Builds and log reads don't need it (builds use scripts/heavy-lock.sh).
# Never remove another project's lock. A lock that looks stale is reported to the user, never removed.
#
# usage:
#   gui-lock.sh acquire <run-id> [expected_minutes=30] [purpose] [session=mado-delegator]
#       → exit 0 and `ACQUIRED <run-id> acquisition_id=<uuid>` on stdout; 75 busy
#   gui-lock.sh wait <run-id> [expected_minutes] [purpose] [session] [max_wait_min=60]   → poll 60 s; 75 on timeout
#   gui-lock.sh release <run-id> --acquisition-id <uuid>   → only the acquisition that printed this id
#   gui-lock.sh status
# Refusals and usage errors exit 1 with `REFUSED: …` on stderr (mdpro's codes).
exec /usr/bin/python3 - "$@" <<'PY'
import datetime
import fcntl
import os
import pathlib
import re
import stat
import sys
import time
import uuid

cache = pathlib.Path.home() / ".cache"
lockdir = cache / "desktop-gui.lock"
mutex = cache / "desktop-gui.mutex"
required = {"project", "session", "batch", "start", "pid", "expected_minutes", "purpose", "acquisition_id"}
uuid4 = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\Z")

class Refused(Exception):
    pass

def valid_text(value):
    # splitlines() also breaks on \v \f \x1c-\x1e \x85 U+2028 U+2029, so refuse anything read_owner would split.
    if not value or "\0" in value or len(value.splitlines()) != 1 or value.splitlines()[0] != value:
        raise Refused("invalid owner field value")
    return value

def with_mutex(operation):
    cache.mkdir(parents=True, exist_ok=True)
    fd = os.open(mutex, os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0), 0o600)
    try:
        checkpoint = os.environ.get("MADO_GUI_LOCK_PRE_MUTEX_FILE")
        if checkpoint and os.environ.get("MADO_GUI_LOCK_TEST") == "1":
            pathlib.Path(checkpoint).touch()
        fcntl.flock(fd, fcntl.LOCK_EX)
        return operation()
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)

def read_owner():
    if lockdir.is_symlink() or not lockdir.is_dir():
        raise Refused("lock directory is absent or symlinked")
    fd = os.open(lockdir / "owner", os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise Refused("owner is not a regular file")
        raw = os.read(fd, 8193)
        if len(raw) > 8192:
            raise Refused("owner is too large")
    finally:
        os.close(fd)
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as error:
        raise Refused("owner is not UTF-8") from error
    values = {}
    for line in text.splitlines():
        if "=" not in line:
            raise Refused("malformed owner line")
        key, value = line.split("=", 1)
        if key not in required or key in values:
            raise Refused("unknown or duplicate owner field")
        values[key] = valid_text(value)
    if set(values) != required or not uuid4.fullmatch(values["acquisition_id"]):
        raise Refused("missing or malformed owner field")
    return raw, values

def publish_owner(owner):
    fd = os.open(lockdir / "owner", os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
    # An incomplete owner keeps the directory occupied and later operations fail closed.
    with os.fdopen(fd, "wb") as stream:
        stream.write(owner)
        stream.flush()
        os.fsync(stream.fileno())

def acquire(batch, expected, purpose, session):
    batch, purpose, session = map(valid_text, (batch, purpose, session))
    if not expected.isdecimal() or int(expected) <= 0:
        raise Refused("invalid expected minutes")
    def transaction():
        try:
            os.mkdir(lockdir, 0o700)
        except FileExistsError:
            return None
        acquisition_id = str(uuid.uuid4())
        owner = (
            f"project=picsee\nsession={session}\nbatch={batch}\n"
            f"start={datetime.datetime.now().astimezone().strftime('%Y-%m-%dT%H:%M:%S%z')}\n"
            f"pid={os.getpid()}\nexpected_minutes={expected}\npurpose={purpose}\n"
            f"acquisition_id={acquisition_id}\n"
        )
        publish_owner(owner.encode("utf-8"))
        return acquisition_id
    return with_mutex(transaction)

def release(batch, acquisition_id):
    valid_text(batch)
    if not uuid4.fullmatch(acquisition_id):
        raise Refused("invalid acquisition id")
    def transaction():
        try:
            raw, values = read_owner()
        except (FileNotFoundError, NotADirectoryError, OSError) as error:
            raise Refused("owner is absent or unreadable") from error
        if values["project"] != "picsee" or values["batch"] != batch or values["acquisition_id"] != acquisition_id:
            raise Refused("not this acquisition")
        os.unlink(lockdir / "owner")
        try:
            os.rmdir(lockdir)
        except OSError as error:
            try:
                publish_owner(raw)
            except OSError as restore_error:
                raise Refused(f"ALERT: release failed and owner restoration failed: {restore_error}") from error
            raise Refused(f"release failed; owner restored: {error}") from error
    with_mutex(transaction)

def show(stream=sys.stdout):
    if not lockdir.exists() and not lockdir.is_symlink():
        print("FREE", file=stream)
        return
    print("HELD:", file=stream)
    if lockdir.is_symlink() or not lockdir.is_dir():
        print("  (invalid lock path; do not start GUI work)", file=stream)
        return
    try:
        fd = os.open(lockdir / "owner", os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        with os.fdopen(fd, "rb") as owner:
            text = owner.read(8192).decode("utf-8", "replace")
        for line in text.splitlines():
            print(f"  {line}", file=stream)
    except OSError:
        print("  (no readable owner file; do not start GUI work)", file=stream)

def main(args):
    command = args[0] if args else "status"
    if command == "status" and len(args) <= 1:
        show()
        return 0
    if command in ("acquire", "wait"):
        if len(args) < 2 or len(args) > (6 if command == "wait" else 5):
            raise Refused("usage: acquire|wait <run-id> [expected] [purpose] [session] [max_wait_min]")
        batch = args[1]
        expected = args[2] if len(args) > 2 else "30"
        purpose = args[3] if len(args) > 3 else "device run"
        session = args[4] if len(args) > 4 else "mado-delegator"
        attempts = 1 if command == "acquire" else int(args[5]) if len(args) > 5 else 60
        if attempts <= 0:
            raise Refused("invalid wait limit")
        interval = 60.0
        if os.environ.get("MADO_GUI_LOCK_TEST") == "1":
            interval = float(os.environ.get("MADO_GUI_LOCK_WAIT_SECONDS", "60"))
            if not 0 <= interval <= 60:
                raise Refused("invalid test wait interval")
        for attempt in range(attempts):
            acquisition_id = acquire(batch, expected, purpose, session)
            if acquisition_id is not None:
                print(f"ACQUIRED {batch} acquisition_id={acquisition_id}")
                return 0
            if attempt + 1 < attempts:
                time.sleep(interval)
        print("BUSY" if command == "acquire" else "TIMEOUT: still held; report to the user, do not remove it",
              file=sys.stderr)
        show(sys.stderr)
        return 75
    if command == "release":
        if len(args) != 4 or args[2] != "--acquisition-id":
            raise Refused("usage: release <run-id> --acquisition-id <uuid>")
        release(args[1], args[3])
        print(f"RELEASED {args[1]}")
        return 0
    raise Refused("usage: gui-lock.sh acquire|wait|release|status")

try:
    sys.exit(main(sys.argv[1:]))
except (Refused, ValueError) as error:
    print(f"REFUSED: {error}", file=sys.stderr)
    sys.exit(1)
except OSError as error:
    print(f"FAIL: {error}", file=sys.stderr)
    sys.exit(1)
PY
