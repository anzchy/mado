#!/usr/bin/env python3
"""Run a shipped roster poller, then notify one explicitly pinned delegator."""

import argparse
import fcntl
import importlib.util
import json
import math
import os
import re
import signal
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from contextlib import contextmanager
from pathlib import Path


class DeliveryError(RuntimeError):
    """The queue transport failed after all configured attempts."""


class DeliveryUncertain(RuntimeError):
    """A Claude pane send may have happened; never replay without reconciliation."""


class DeliveryDeferred(RuntimeError):
    """The Claude input box was not seen empty before the typing deadline; nothing was sent."""


class EventIdentityError(RuntimeError):
    """An event ID was reused for a different task or destination."""


IDENTITY_FIELDS = ("schema", "event", "task", "agent", "thread", "destination",
                   "handoff", "handoff_marker", "poll")
REQUIRED_FIELDS = ("schema", "event", "task", "agent", "handoff", "poll", "created_at")
EVENT_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
PANE_PATTERN = re.compile(r"^w[0-9]+:p[0-9]+$")
TERMINAL_PATTERN = re.compile(r"^term_[A-Za-z0-9_-]+$")
# Claude Code's input box sits between two full-width rules; the top one may end in " <label> ─".
RULE_PATTERN = re.compile(r"^─{20,}(?: [^\n]* ─)?$")
ANSI_PATTERN = re.compile(r"\x1b\[([0-?]*)([ -/]*)([@-~])|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[@-_]")
# SGR codes that change neither intensity nor visibility: bold, italic, underline, blink, inverse,
# hidden, strike, their resets, and the basic/bright colours with their defaults.
NEUTRAL_SGR = frozenset([1, 3, 4, 5, 7, 8, 9, 23, 24, 25, 27, 28, 29, 39, 49, 59,
                         *range(30, 38), *range(40, 48), *range(90, 98), *range(100, 108)])
# The last line Claude Code draws under an open selection dialog (AskUserQuestion, folder trust),
# seen on 2.1.310: "Enter to select · ↑/↓ to navigate · Esc to cancel" or "Enter to confirm · Esc to cancel".
DIALOG_FOOTER_PATTERN = re.compile(r"^Enter to (?:select|confirm) · (?:[^\n]* · )?Esc to cancel$")
# The selection cursor on a dialog option, e.g. "❯ 1. Red" or " ❯ No, exit".
DIALOG_CURSOR_PATTERN = re.compile(r"^\s*❯\s+\S")
TYPING_GIVE_UP_SECONDS = 14400
TYPING_SLOW_RETRY_SECONDS = 60
ATTENTION_AFTER_SECONDS = 600
# One saved unreadable read per event: the tail of the raw ANSI text and of its plain lines,
# each file at most SNAPSHOT_BYTES of UTF-8.
SNAPSHOT_BYTES = 65536
SNAPSHOT_LINES = 200
ATTENTION_STATES = ("deferred-user-typing", "delivery-uncertain", "delivery-failed", "launch-failed")
REPORT_SPEC = importlib.util.spec_from_file_location(
    "picsee_poll_report", Path(__file__).with_name("poll-report.py")
)
REPORT_POLL = importlib.util.module_from_spec(REPORT_SPEC)
REPORT_SPEC.loader.exec_module(REPORT_POLL)
_THREAD_LOCKS = {}
_THREAD_LOCKS_GUARD = threading.Lock()


def _atomic_json(path, value):
    path = Path(path)
    temporary = path.with_name(path.name + ".tmp-" + str(os.getpid()))
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    os.replace(str(temporary), str(path))


def _atomic_text(path, value):
    path = Path(path)
    temporary = path.with_name(path.name + ".tmp-" + str(os.getpid()))
    temporary.write_text(value)
    os.replace(str(temporary), str(path))


def _read_json(path):
    return json.loads(Path(path).read_text())


def _identity(config):
    return {field: config.get(field) for field in IDENTITY_FIELDS}


def _validate_config(config):
    missing = [field for field in REQUIRED_FIELDS if field not in config]
    if missing:
        raise ValueError("missing config fields: " + ", ".join(missing))
    if type(config["schema"]) is not int or config["schema"] not in (1, 2):
        raise ValueError("unsupported config schema")
    if not EVENT_PATTERN.fullmatch(config["event"]):
        raise ValueError("event must use only letters, numbers, dot, underscore, or hyphen")
    if config["schema"] == 1:
        if "thread" not in config or "destination" in config:
            raise ValueError("schema 1 requires thread and no destination")
        try:
            uuid.UUID(config["thread"])
        except (AttributeError, TypeError, ValueError) as error:
            raise ValueError("thread must be an explicit UUID") from error
    else:
        if "thread" in config or not isinstance(config.get("destination"), dict):
            raise ValueError("schema 2 requires destination and no legacy thread")
        destination = config["destination"]
        if destination.get("kind") == "codex-thread":
            if set(destination) != {"kind", "thread"}:
                raise ValueError("codex destination must contain only kind and thread")
            try:
                uuid.UUID(destination["thread"])
            except (AttributeError, TypeError, ValueError) as error:
                raise ValueError("thread must be an explicit UUID") from error
        elif destination.get("kind") == "claude-pane":
            if set(destination) != {"kind", "pane", "terminal_id", "cwd"}:
                raise ValueError("claude destination requires pane, terminal_id and cwd")
            if not isinstance(destination["pane"], str) or not PANE_PATTERN.fullmatch(destination["pane"]):
                raise ValueError("pane must be an explicit herdr pane ID")
            if (not isinstance(destination["terminal_id"], str)
                    or not TERMINAL_PATTERN.fullmatch(destination["terminal_id"])):
                raise ValueError("terminal_id must be an explicit herdr terminal ID")
            cwd = destination["cwd"]
            if not isinstance(cwd, str) or not Path(cwd).is_absolute() or "\n" in cwd or "\r" in cwd:
                raise ValueError("cwd must be an absolute single-line path")
        else:
            raise ValueError("unsupported destination kind")
    handoff = Path(config["handoff"])
    if not handoff.is_absolute():
        raise ValueError("handoff must be an absolute path")
    poll = config["poll"]
    if not isinstance(poll, list) or not poll or not all(isinstance(item, str) for item in poll):
        raise ValueError("poll must be a non-empty argv list")
    if Path(poll[0]).name == "poll-report.py":
        task, marker = config["task"], config.get("handoff_marker")
        if (not isinstance(task, str) or not task.strip() or "\n" in task or "\r" in task
                or not isinstance(marker, str) or not marker.strip()
                or "\n" in marker or "\r" in marker):
            raise ValueError("report polling requires non-empty, single-line task and handoff_marker")
        if marker != task or len(poll) < 8 or poll[4] != task:
            raise ValueError("report polling requires handoff_marker and poll identity equal to task")
        if poll[1] != config["agent"] or Path(poll[2]) != handoff:
            raise ValueError("report polling requires the poll agent and report path to match config")
    attempts = config.get("max_delivery_attempts", 5)
    backoff = config.get("initial_backoff_seconds", 5)
    if not isinstance(attempts, int) or attempts < 1 or attempts > 10:
        raise ValueError("max_delivery_attempts must be between 1 and 10")
    if not isinstance(backoff, (int, float)) or backoff < 0 or backoff > 300:
        raise ValueError("initial_backoff_seconds must be between 0 and 300")
    retry = config.get("typing_retry_seconds", 5)
    if (not isinstance(retry, (int, float)) or isinstance(retry, bool) or not math.isfinite(retry)
            or retry <= 0 or retry > 300):
        raise ValueError("typing_retry_seconds must be above 0 and at most 300")
    hold = config.get("typing_defer_seconds", 900)
    if (not isinstance(hold, (int, float)) or isinstance(hold, bool) or not math.isfinite(hold)
            or hold < 0 or hold > 86400):
        raise ValueError("typing_defer_seconds must be between 0 and 86400")
    give_up = _typing_give_up_seconds(config)
    if (not isinstance(give_up, (int, float)) or isinstance(give_up, bool) or not math.isfinite(give_up)
            or give_up < 0 or give_up > 86400):
        raise ValueError("typing_give_up_seconds must be between 0 and 86400")
    if give_up < hold:
        raise ValueError("typing_give_up_seconds must be at least typing_defer_seconds")
    alert = config.get("attention_after_seconds", ATTENTION_AFTER_SECONDS)
    if (not isinstance(alert, (int, float)) or isinstance(alert, bool) or not math.isfinite(alert)
            or alert <= 0 or alert > 86400):
        raise ValueError("attention_after_seconds must be above 0 and at most 86400")
    deadline = config.get("poll_deadline_seconds")
    if deadline is not None and (
        not isinstance(deadline, (int, float)) or not math.isfinite(deadline) or deadline <= 0
    ):
        raise ValueError("poll_deadline_seconds must be finite and positive")


def _typing_give_up_seconds(config):
    # Events registered before this bound existed keep retrying for at least four hours.
    return config.get("typing_give_up_seconds",
                      max(TYPING_GIVE_UP_SECONDS, config.get("typing_defer_seconds", 900)))


def _seconds(value):
    return "{:g}".format(value)


def _thread_lock(path):
    key = str(Path(path).resolve())
    with _THREAD_LOCKS_GUARD:
        return _THREAD_LOCKS.setdefault(key, threading.Lock())


@contextmanager
def _locked(path):
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    with _thread_lock(path):
        with Path(path).open("a") as lock_file:
            fcntl.flock(lock_file, fcntl.LOCK_EX)
            try:
                yield
            finally:
                fcntl.flock(lock_file, fcntl.LOCK_UN)


def register_event(event_dir, config):
    """Persist an immutable event identity under a short registration lock."""
    _validate_config(config)
    event_dir = Path(event_dir)
    event_dir.mkdir(parents=True, exist_ok=True)
    config_path = event_dir / "config.json"
    with _locked(event_dir / "register.lock"):
        if config_path.exists():
            existing = _read_json(config_path)
            if _identity(existing) != _identity(config):
                raise EventIdentityError(
                    "event ID already exists with a different identity: " + config["event"]
                )
            return "already-registered"
        _atomic_json(config_path, config)
        return "registered"


def _handoff_evidence(config):
    handoff = Path(config["handoff"])
    if Path(config["poll"][0]).name == "poll-report.py":
        return REPORT_POLL.report_evidence(handoff, config["created_at"], config["task"])
    if not handoff.exists():
        return "missing"
    marker = config.get("handoff_marker")
    if marker and marker not in handoff.read_text(errors="replace"):
        return "stale"
    if handoff.stat().st_mtime < config["created_at"]:
        return "stale"
    return "ready"


def _classify_poll(returncode, output):
    lowered = output.lower()
    if returncode != 0:
        return "timeout" if re.search(r"\btimeout\b", lowered) else "poll-error"
    for outcome in ("missing-handoff", "question", "blocked", "timeout", "idle", "done"):
        if re.search(r"\b" + outcome + r"\b", lowered):
            return outcome
    return "poll-error"


def _poll_deadline_seconds(config):
    if "poll_deadline_seconds" in config:
        return config["poll_deadline_seconds"]
    # Existing registered events predate the stored deadline. Recover the shipped
    # poller's configured maximum rather than silently giving them an infinite wait.
    poll = config["poll"]
    name = Path(poll[0]).name
    if name in ("poll-idle.sh", "poll-handoff.sh") and len(poll) >= 4:
        try:
            minutes = int(poll[3])
            interval = int(poll[2]) if name == "poll-idle.sh" else 60
            if minutes > 0 and interval > 0:
                return minutes * 60 + interval + 10
        except ValueError:
            pass
    if name == "poll-report.py" and len(poll) >= 7:
        try:
            return float(poll[6]) * 60 + float(poll[5]) + 10
        except (IndexError, ValueError):
            pass
    return 600 * 60 + 70


def _run_poll_process(argv, deadline):
    # A file avoids waiting forever on a pipe still held open by a hung descendant.
    with tempfile.TemporaryDirectory() as temporary, tempfile.TemporaryFile(mode="w+t") as output:
        status = Path(temporary) / "poll-exit-code"
        # Keep the private group leader alive after the poller exits. Its PID stays
        # reserved until cleanup, so a reused process group can never be signalled.
        process = subprocess.Popen(
            [sys.executable, str(Path(__file__).resolve()), "__poll_supervisor", str(status), *argv],
            stdin=subprocess.PIPE, stdout=output, stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        expired = False
        cleanup_error = None
        try:
            end = time.monotonic() + deadline
            while not status.exists():
                remaining = end - time.monotonic()
                if remaining <= 0:
                    expired = True
                    break
                time.sleep(min(0.01, remaining))
        finally:
            # The supervisor is still running (or an unreaped zombie), pinning its
            # PID throughout both signals. Never inspect/reap it before this point.
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except OSError as error:
                cleanup_error = error
            time.sleep(0.2)
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except OSError as error:
                cleanup_error = cleanup_error or error
            try:
                process.wait(timeout=1)
            except subprocess.TimeoutExpired as error:
                cleanup_error = cleanup_error or error
            if process.stdin:
                process.stdin.close()
        if cleanup_error is not None:
            raise RuntimeError("poll process group cleanup failed: " + str(cleanup_error))
        if expired:
            raise subprocess.TimeoutExpired(argv, deadline)
        if not status.exists():
            raise RuntimeError("poll supervisor exited without a result")
        output.seek(0)
        return subprocess.CompletedProcess(argv, int(status.read_text()), output.read(65536), "")


def _poll_supervisor(status, argv):
    # A caught handler is reset by exec in the child, while the supervisor stays
    # alive through TERM until its owner finishes the group with KILL.
    signal.signal(signal.SIGTERM, lambda _signum, _frame: None)
    child = subprocess.Popen(argv, stdin=subprocess.DEVNULL)
    code = child.wait()
    Path(status).write_text(str(code))
    sys.stdin.buffer.read()


def _run_poll(event_dir, config, run):
    _atomic_json(event_dir / "status.json", {"state": "polling", "event": config["event"]})
    try:
        deadline = _poll_deadline_seconds(config)
        if run is subprocess.run:
            completed = _run_poll_process(config["poll"], deadline)
        else:
            completed = run(config["poll"], capture_output=True, text=True, timeout=deadline)
        output = "\n".join(part.strip() for part in (completed.stdout, completed.stderr) if part.strip())
        result = {
            "exit_code": completed.returncode,
            "output": output,
            "outcome": _classify_poll(completed.returncode, output),
            "handoff_evidence": _handoff_evidence(config),
            "recorded_at": time.time(),
        }
    except Exception as error:
        result = {
            "exit_code": None,
            "output": type(error).__name__ + ": " + str(error),
            "outcome": "timeout" if isinstance(error, subprocess.TimeoutExpired) else "poll-error",
            "handoff_evidence": _handoff_evidence(config),
            "recorded_at": time.time(),
        }
    _atomic_json(event_dir / "poll-result.json", result)
    return result


def _notification_message(config, poll_result):
    evidence = poll_result["handoff_evidence"]
    if poll_result["outcome"] in ("idle", "done") and evidence == "ready":
        next_step = "Handoff evidence is fresh; inspect it and the current SHA before continuing."
    else:
        next_step = (
            "This needs inspection: resolve the question, blocker, timeout, poll error, or "
            "missing/stale handoff before continuing."
        )
    return (
        "[picsee-listener event {event}] Automated roster status notification. "
        "Task: {task}. Agent: {agent}. Poll outcome: {outcome} (exit {exit_code}). "
        "Expected handoff/report: {handoff}; evidence: {evidence}. {next_step} "
        "Poll completion is not audit acceptance. Continue the delegator workflow only after "
        "checking the pane, report, task identity, and SHA. Do not resend this event after a "
        "queue receipt exists."
    ).format(
        event=config["event"],
        task=config["task"],
        agent=config["agent"],
        outcome=poll_result["outcome"],
        exit_code=poll_result["exit_code"],
        handoff=config["handoff"],
        evidence=evidence,
        next_step=next_step,
    )


def _destination(config):
    return ({"kind": "codex-thread", "thread": config["thread"]}
            if config["schema"] == 1 else config["destination"])


def _checked_claude_pane(destination, run):
    argv = ["herdr", "pane", "list"]
    completed = run(argv, capture_output=True, text=True, timeout=30)
    if completed.returncode != 0:
        raise ValueError("herdr pane list failed: " + (completed.stderr.strip() or completed.stdout.strip()))
    try:
        envelope = json.loads(completed.stdout)
        if (not isinstance(envelope, dict) or envelope.get("id") != "cli:pane:list"
                or "error" in envelope):
            raise ValueError("invalid pane list envelope")
        result = envelope.get("result")
        if not isinstance(result, dict) or result.get("type") != "pane_list":
            raise ValueError("invalid pane list result")
        panes = result.get("panes")
        if not isinstance(panes, list) or not all(isinstance(p, dict) for p in panes):
            raise ValueError("invalid pane list entries")
        matches = [p for p in panes if p.get("pane_id") == destination["pane"]]
        if len(matches) != 1:
            raise ValueError("delegator pane missing or ambiguous")
        pane = matches[0]
        if (pane.get("agent") != "claude"
                or pane.get("terminal_id") != destination["terminal_id"]
                or pane.get("cwd") != destination["cwd"]
                or pane.get("foreground_cwd") != destination["cwd"]):
            raise ValueError("delegator pane identity changed")
    except (json.JSONDecodeError, TypeError, KeyError) as error:
        raise ValueError("malformed herdr pane list") from error


def _sgr_dim(params, dim):
    """Apply one SGR parameter string to the dim flag.

    Only encodings recognised in full keep text dim. Anything else clears the flag, so an
    unrecognised style can make text count as typed, never as an empty box.
    """
    if not re.fullmatch(r"[0-9;:]*", params):
        return False
    codes = params.split(";")
    index = 0
    while index < len(codes):
        code = codes[index]
        if ":" in code:
            # ITU colon form keeps one colour in a single parameter: 38:5:n or 38:2:[space]:r:g:b.
            parts = code.split(":")
            if parts[0] not in ("38", "48", "58"):
                return False
            if parts[1:2] == ["5"] and len(parts) == 3 and parts[2].isdigit():
                pass
            elif (parts[1:2] == ["2"] and len(parts) in (5, 6) and all(p.isdigit() for p in parts[-3:])
                    and (len(parts) == 5 or parts[2] == "" or parts[2].isdigit())):
                pass
            else:
                return False
            index += 1
            continue
        if code in ("38", "48", "58"):
            # Extended colour: 5;n or 2;r;g;b. Its parameters are not attributes.
            if codes[index + 1:index + 2] == ["5"] and codes[index + 2:index + 3] and codes[index + 2].isdigit():
                index += 3
            elif (codes[index + 1:index + 2] == ["2"] and len(codes[index + 2:index + 5]) == 3
                    and all(p.isdigit() for p in codes[index + 2:index + 5])):
                index += 5
            else:
                return False
            continue
        if code and not code.isdigit():
            return False
        value = int(code or 0)
        if value in (0, 22):
            dim = False
        elif value == 2:
            dim = True
        elif value not in NEUTRAL_SGR:
            return False
        index += 1
    return dim


def _parse_screen(screen):
    """Split an ANSI pane snapshot into plain lines, undimmed lines and rule line indexes."""
    plain, visible = [], []
    dim = False
    for line in screen.replace("\r", "").split("\n"):
        text, undimmed, position = [], [], 0
        for match in [*ANSI_PATTERN.finditer(line), None]:
            chunk = line[position:match.start() if match else len(line)]
            text.append(chunk)
            if not dim:
                undimmed.append(chunk)
            if match is None:
                break
            position = match.end()
            if match.group(3) == "m":
                dim = False if match.group(2) else _sgr_dim(match.group(1), dim)
        plain.append("".join(text).rstrip())
        visible.append("".join(undimmed))
    rules = [index for index, line in enumerate(plain) if RULE_PATTERN.fullmatch(line)]
    return plain, visible, rules


def _claude_input_state(screen):
    """Classify the Claude Code input box in an ANSI pane snapshot: empty, typing, dialog or unknown.

    A dialog needs its footer as the last drawn line, a rule line above it, and a selection
    cursor between the rule that opens it and the footer: the second-last rule for
    AskUserQuestion, the last for a trust prompt. Otherwise the box is the
    text between the last two rule lines, and its first line must start with the prompt glyph.
    Dim (SGR 2) text is Claude's grey prompt suggestion, not input; an SGR encoding it does not
    fully recognise ends dim text (see `_sgr_dim`). Anything else, including a missing box or
    another prompt glyph, is unknown. Only empty lets a send through.
    """
    plain, visible, rules = _parse_screen(screen)
    drawn = [index for index, line in enumerate(plain) if line.strip()]
    if drawn and rules and DIALOG_FOOTER_PATTERN.fullmatch(plain[drawn[-1]].strip()):
        opening = rules[-2] if len(rules) >= 2 else rules[-1]
        if any(DIALOG_CURSOR_PATTERN.match(line) for line in plain[opening + 1:drawn[-1]]):
            return "dialog"
    if len(rules) < 2 or rules[-1] - rules[-2] < 2 or not plain[rules[-2] + 1].startswith("❯"):
        return "unknown"
    box = visible[rules[-2] + 1:rules[-1]]
    box[0] = box[0].replace("❯", "", 1)
    return "typing" if any(line.strip() for line in box) else "empty"


def _claude_read(destination, run):
    argv = ["herdr", "pane", "read", destination["pane"], "--source", "visible", "--format", "ansi"]
    completed = run(argv, capture_output=True, text=True, timeout=30)
    if completed.returncode != 0:
        raise ValueError("herdr pane read failed: " + (completed.stderr.strip() or completed.stdout.strip()))
    return completed.stdout


def _utc_now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _save_input_snapshot(event_dir, destination, screen, input_state):
    """Keep the read that classified as unknown, so the screen can be reproduced offline.

    Each file holds at most SNAPSHOT_BYTES: the ANSI file keeps the tail of the read, and the
    JSON file drops plain lines from the top (the box with them) until it fits.
    """
    raw = screen.encode()
    _atomic_text(event_dir / "input-snapshot.ansi", raw[-SNAPSHOT_BYTES:].decode(errors="ignore"))
    plain, _, rules = _parse_screen(screen)
    box_lines = range(rules[-2] + 1, rules[-1]) if len(rules) >= 2 else range(0)
    first_line = max(0, len(plain) - SNAPSHOT_LINES)
    captured_at = _utc_now()
    while True:
        snapshot = {
            "input": input_state, "pane": destination["pane"], "captured_at": captured_at,
            "truncated": len(raw) > SNAPSHOT_BYTES or first_line > 0,
            "lines": plain[first_line:], "rules": [index - first_line for index in rules if index >= first_line],
            "box": [plain[index] for index in box_lines if index >= first_line],
        }
        if len((json.dumps(snapshot, indent=2, sort_keys=True) + "\n").encode()) <= SNAPSHOT_BYTES:
            break
        first_line += 1
    _atomic_json(event_dir / "input-snapshot.json", snapshot)


def _log_attention(event_dir, config, destination, input_state, held):
    # The listeners directory sits in the delegator's state directory; the log sits beside it.
    line = ("{} listener {} input={} held {}s; nothing sent; pane {}; event {}; "
            "run listen-notify.py status\n").format(
        _utc_now(), config["event"], input_state, _seconds(held), destination["pane"], event_dir)
    with (event_dir.parent.parent / "attention.log").open("a") as log:
        log.write(line)


def _accepted_claude_run(completed):
    # Observed on the installed herdr CLI: a successful pane run exits 0 and
    # emits no stdout/stderr. Any other result is not proof of acceptance.
    return completed.returncode == 0 and completed.stdout == "" and completed.stderr == ""


def _uncertain(event_dir, config, reason):
    _atomic_json(event_dir / "status.json", {
        "state": "delivery-uncertain", "event": config["event"], "reason": reason,
    })
    raise DeliveryUncertain("Claude delivery uncertain; inspect pane and event before a new event: " + reason)


def _deliver_claude(event_dir, config, destination, message, run, sleep, clock):
    # Keep the full message out of pane input: if the terminal became a shell,
    # ':' is a no-op and the event ID cannot contain shell metacharacters.
    _atomic_text(event_dir / "notification.txt", message + "\n")
    token = ": PICSEE_LISTENER_EVENT_" + config["event"]
    attempts = config.get("max_delivery_attempts", 5)
    initial_backoff = config.get("initial_backoff_seconds", 5)
    typing_retry = config.get("typing_retry_seconds", 5)
    typing_hold = config.get("typing_defer_seconds", 900)
    give_up = _typing_give_up_seconds(config)
    alert_after = config.get("attention_after_seconds", ATTENTION_AFTER_SECONDS)
    hold_start = None
    snapshot_saved = alerted = False
    errors = []
    attempt = 1
    while attempt <= attempts:
        # Once the alert is logged, every later status write keeps the flag for `status`.
        flag = {"attention": True} if alerted else {}
        _atomic_json(event_dir / "status.json", {
            "state": "delivering", "event": config["event"], "attempt": attempt, **flag,
        })
        try:
            _checked_claude_pane(destination, run)
            screen = _claude_read(destination, run)
            input_state = _claude_input_state(screen)
            if input_state == "empty":
                if hold_start is not None:
                    _atomic_text(event_dir / "notification.txt", message + "\nSend held {}s while the Claude "
                                 "input box was not empty.\n".format(_seconds(round(clock() - hold_start, 1))))
                # Persist uncertainty *before* the gate read, so nothing but that read sits
                # between the last look at the box and the send. A crash here leaves the
                # event uncertain with nothing sent, which is the safe direction.
                _atomic_json(event_dir / "status.json", {
                    "state": "delivery-uncertain", "event": config["event"],
                    "attempt": attempt, "reason": "gate read entered; pane run follows only if the box is empty",
                })
                screen = _claude_read(destination, run)
                input_state = _claude_input_state(screen)
        except Exception as error:
            errors.append(type(error).__name__ + ": " + str(error))
            # Nothing was sent: a failed list or read never reaches the transport.
            _atomic_json(event_dir / "status.json", {
                "state": "delivering", "event": config["event"], "attempt": attempt, "last_error": errors[-1],
                **flag,
            })
            if attempt < attempts:
                sleep(min(initial_backoff * (2 ** (attempt - 1)), 300))
            attempt += 1
            continue

        # Text in the box (or a screen we cannot read) may be a human typing. Hold the
        # send without touching the box; holding does not use a delivery attempt. The
        # hold runs on a monotonic deadline, so slow herdr calls count toward it.
        if input_state != "empty":
            now = clock()
            hold_start = now if hold_start is None else hold_start
            held = round(now - hold_start, 1)
            if input_state == "unknown" and not snapshot_saved:
                _save_input_snapshot(event_dir, destination, screen, input_state)
                snapshot_saved = True
            # A dialog or unreadable screen is nobody typing: say so early, once per run.
            if input_state in ("dialog", "unknown") and not alerted and held >= alert_after:
                _log_attention(event_dir, config, destination, input_state, held)
                alerted = True
            flag = {"attention": True} if alerted else {}
            if held >= give_up:
                _atomic_json(event_dir / "status.json", {
                    "state": "deferred-user-typing", "event": config["event"],
                    "input": input_state, "deferred_seconds": held, "retrying": False, **flag,
                })
                raise DeliveryDeferred(
                    "Claude input box not empty ({}) for {}s; nothing sent, event kept for a later run".format(
                        input_state, _seconds(held)))
            # Past the hold window the event is reported as deferred but still re-checked,
            # less often, until the give-up bound.
            if held < typing_hold:
                state, wait = "waiting-user-typing", min(typing_retry, typing_hold - held)
            else:
                state, wait = "deferred-user-typing", max(typing_retry, TYPING_SLOW_RETRY_SECONDS)
            wait = min(wait, give_up - held)
            _atomic_json(event_dir / "status.json", {
                "state": state, "event": config["event"], "input": input_state,
                "deferred_seconds": held, "retry_in_seconds": wait, "retrying": True, **flag,
            })
            sleep(wait)
            continue

        # Uncertainty is already persisted before the transport. A crash, timeout,
        # lost response, or receipt-write failure can never trigger a replay.
        argv = ["herdr", "pane", "run", destination["pane"], token]
        try:
            completed = run(argv, capture_output=True, text=True, timeout=30)
        except Exception as error:
            _uncertain(event_dir, config, type(error).__name__ + ": " + str(error))
        if not _accepted_claude_run(completed):
            _uncertain(event_dir, config, "pane run did not return observed exit-0/empty success")
        try:
            _checked_claude_pane(destination, run)
        except Exception as error:
            _uncertain(event_dir, config, "post-send pane identity changed: " + str(error))

        _atomic_json(event_dir / "queue-receipt.json", {
            "event": config["event"], "task": config["task"], "agent": config["agent"],
            "destination": destination, "queued_at": time.time(), "attempt": attempt,
            "queue_response": "", "transport_observation": "herdr pane run exit 0, empty output; postflight matched",
        })
        _atomic_json(event_dir / "status.json", {
            "state": "delivered", "event": config["event"], "attempt": attempt,
        })
        return "delivered"

    _atomic_json(event_dir / "status.json", {
        "state": "delivery-failed", "event": config["event"],
        "attempts": attempts, "last_error": errors[-1],
    })
    raise DeliveryError("Claude preflight failed before send after {} attempts: {}".format(
        attempts, errors[-1]))


def _deliver(event_dir, config, poll_result, run, sleep, clock):
    receipt_path = event_dir / "queue-receipt.json"
    with _locked(event_dir / "delivery.lock"):
        if receipt_path.exists():
            return "already-delivered"
        status_path = event_dir / "status.json"
        if status_path.exists() and _read_json(status_path).get("state") == "delivery-uncertain":
            raise DeliveryUncertain("Claude delivery uncertain; reconcile this event before any retry")
        message = _notification_message(config, poll_result)
        destination = _destination(config)
        if destination["kind"] == "claude-pane":
            return _deliver_claude(event_dir, config, destination, message, run, sleep, clock)
        attempts = config.get("max_delivery_attempts", 5)
        initial_backoff = config.get("initial_backoff_seconds", 5)
        errors = []
        for attempt in range(1, attempts + 1):
            _atomic_json(
                event_dir / "status.json",
                {"state": "delivering", "event": config["event"], "attempt": attempt},
            )
            try:
                argv = ["codex", "queue", "--thread", destination["thread"],
                        "--message", message]
                completed = run(argv, capture_output=True, text=True, timeout=30)
                if completed.returncode == 0:
                    response = completed.stdout.strip() or completed.stderr.strip()
                    receipt = {
                        "event": config["event"],
                        "task": config["task"],
                        "agent": config["agent"],
                        "queued_at": time.time(),
                        "attempt": attempt,
                        "queue_response": response,
                    }
                    if config["schema"] == 1:
                        receipt["thread"] = config["thread"]
                    else:
                        receipt["destination"] = destination
                    _atomic_json(
                        receipt_path,
                        receipt,
                    )
                    _atomic_json(
                        event_dir / "status.json",
                        {"state": "delivered", "event": config["event"], "attempt": attempt},
                    )
                    return "delivered"
                errors.append(completed.stderr.strip() or completed.stdout.strip() or "delivery not acknowledged")
            except Exception as error:
                errors.append(type(error).__name__ + ": " + str(error))
            if attempt < attempts:
                sleep(min(initial_backoff * (2 ** (attempt - 1)), 300))
        _atomic_json(
            event_dir / "status.json",
            {
                "state": "delivery-failed",
                "event": config["event"],
                "attempts": attempts,
                "last_error": errors[-1],
            },
        )
        raise DeliveryError("queue delivery failed after {} attempts: {}".format(attempts, errors[-1]))


def run_event(event_dir, run=subprocess.run, sleep=time.sleep, clock=time.monotonic):
    """Run or reuse the poll result, then deliver one serialized queue notification."""
    event_dir = Path(event_dir)
    config = _read_json(event_dir / "config.json")
    _validate_config(config)
    if (event_dir / "queue-receipt.json").exists():
        return "already-delivered"
    poll_path = event_dir / "poll-result.json"
    poll_result = _read_json(poll_path) if poll_path.exists() else _run_poll(event_dir, config, run)
    return _deliver(event_dir, config, poll_result, run, sleep, clock)


def _worker_state(path):
    """`running`, `stopped`, or `foreign` when a stale pid now belongs to another user's process."""
    try:
        pid = int(Path(path).read_text())
        os.kill(pid, 0)
        return "running"
    except PermissionError:
        return "foreign"
    except (FileNotFoundError, ProcessLookupError, ValueError):
        return "stopped"


def _pid_is_running(path):
    return _worker_state(path) == "running"


def start_listener(event_dir, config, launch=subprocess.Popen):
    """Register and detach one worker without holding a lock during its poll."""
    event_dir = Path(event_dir)
    register_event(event_dir, config)
    with _locked(event_dir / "launch.lock"):
        if (event_dir / "queue-receipt.json").exists():
            return "already-delivered"
        status_path = event_dir / "status.json"
        if status_path.exists() and _read_json(status_path).get("state") == "delivery-uncertain":
            raise DeliveryUncertain("Claude delivery uncertain; reconcile this event before any retry")
        if _pid_is_running(event_dir / "pid"):
            return "already-running"
        _atomic_json(event_dir / "status.json", {"state": "launching", "event": config["event"]})
        log_file = (event_dir / "listener.log").open("a")
        try:
            try:
                process = launch(
                    [sys.executable, str(Path(__file__).resolve()), "run", "--event-dir", str(event_dir)],
                    stdin=subprocess.DEVNULL,
                    stdout=log_file,
                    stderr=subprocess.STDOUT,
                    start_new_session=True,
                    close_fds=True,
                )
            except Exception as error:
                _atomic_json(
                    event_dir / "status.json",
                    {"state": "launch-failed", "event": config["event"], "error": str(error)},
                )
                raise
        finally:
            log_file.close()
        (event_dir / "pid").write_text(str(process.pid) + "\n")
        return "started"


def listener_status(state_root):
    """One line per undelivered event; an `attention` line needs the delegator."""
    lines, attention = [], False
    root = Path(state_root)
    for event_dir in sorted(root.iterdir()) if root.is_dir() else []:
        if not (event_dir / "config.json").is_file():
            continue
        try:
            status = _read_json(event_dir / "status.json")
        except (OSError, ValueError):
            status = {}
        state = status.get("state", "missing") if isinstance(status, dict) else "invalid"
        if state == "delivered":
            continue
        if not isinstance(status, dict):
            status = {}
        worker = _worker_state(event_dir / "pid")
        flag = ("attention" if state in ATTENTION_STATES + ("invalid",) or worker != "running"
                or status.get("attention") is True else "active")
        attention = attention or flag == "attention"
        line = "{} {} state={} worker={}".format(flag, event_dir.name, state, worker)
        for field in ("input", "deferred_seconds", "retrying", "reason", "last_error"):
            if field in status:
                value = status[field]
                if isinstance(value, (int, float)) and not isinstance(value, bool):
                    value = _seconds(value)
                line += " {}={}".format(field, value)
        lines.append(line)
    # #672: heavy-lock writes one record per holder that exceeded its budget into
    # lock-alerts/ beside the listeners directory. Each stays `attention` until the
    # delegator moves it into lock-alerts/acked/.
    alerts = root.parent / "lock-alerts"
    for path in sorted(alerts.glob("*.json")) if alerts.is_dir() else []:
        try:
            alert = _read_json(path)
        except (OSError, ValueError):
            alert = None
        attention = True
        if not isinstance(alert, dict):
            lines.append("attention lock-alert {} state=invalid file={}".format(path.stem, path))
            continue
        budget = alert.get("budgetSeconds")
        lines.append("attention lock-alert {} phase={} cleanup={} budget={}s pid={} pgid={} file={}".format(
            alert.get("id", path.stem), alert.get("phase"), alert.get("cleanup"),
            _seconds(budget) if isinstance(budget, (int, float)) and not isinstance(budget, bool) else budget,
            alert.get("pid"), alert.get("pgid"), path))
    return lines, attention


def _positive_int(value):
    parsed = int(value)
    if parsed < 1:
        raise argparse.ArgumentTypeError("must be at least 1")
    return parsed


def _build_parser():
    parser = argparse.ArgumentParser(
        description="Detach a shipped picsee roster poller and notify one explicit delegator route."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)
    start = subparsers.add_parser("start", help="register and detach a listener")
    start.add_argument("--event", required=True, help="unique ID for this dispatch or fix/audit round")
    start.add_argument("--task", required=True, help="task or round identity shown in the notification")
    start.add_argument("--route", choices=("codex-thread", "claude-pane"),
                       help="explicit route for new events; omit only for legacy Codex --thread")
    start.add_argument("--thread", help="exact delegator Codex thread UUID")
    start.add_argument("--pane", help="exact Claude delegator herdr pane ID")
    start.add_argument("--terminal-id", help="exact Claude delegator terminal ID from herdr pane list")
    start.add_argument("--cwd", help="absolute Claude delegator repo cwd from herdr pane list")
    start.add_argument("--agent", required=True)
    start.add_argument("--handoff", required=True, help="absolute expected handoff or report path")
    start.add_argument("--poll", required=True, choices=("idle", "handoff", "report"))
    start.add_argument("--interval", type=_positive_int, default=120, help="poll-idle interval seconds")
    start.add_argument("--max-minutes", type=_positive_int, default=600)
    start.add_argument("--handoff-marker", help="fresh round marker required in a handoff")
    start.add_argument("--idle-grace-seconds", type=_positive_int, default=180,
                       help="report mode: time to surface idle without a fresh report")
    start.add_argument("--max-delivery-attempts", type=_positive_int, default=5)
    start.add_argument("--initial-backoff-seconds", type=float, default=5)
    start.add_argument("--typing-retry-seconds", type=float, default=5,
                       help="claude-pane: re-check interval while the input box holds text")
    start.add_argument("--typing-defer-seconds", type=float, default=900,
                       help="claude-pane: hold time before recording deferred-user-typing")
    start.add_argument("--typing-give-up-seconds", type=float,
                       help="claude-pane: stop re-checking a deferred send (default max(14400, defer))")
    start.add_argument("--attention-after-seconds", type=float, default=ATTENTION_AFTER_SECONDS,
                       help="claude-pane: log a dialog or unreadable box held this long to attention.log")
    default_root = Path.home() / ".picsee" / "herdr" / "delegator" / "listeners"
    start.add_argument("--state-root", type=Path, default=default_root)
    status = subparsers.add_parser("status", help="list undelivered events; exit 3 if any needs attention")
    status.add_argument("--state-root", type=Path, default=default_root)
    run = subparsers.add_parser("run", help="internal detached worker")
    run.add_argument("--event-dir", required=True, type=Path)
    return parser


def _config_from_args(args):
    script_dir = Path(__file__).resolve().parent
    handoff = str(Path(args.handoff).expanduser().resolve())
    if args.poll == "idle":
        poll = [str(script_dir / "poll-idle.sh"), args.agent, str(args.interval), str(args.max_minutes)]
    elif args.poll == "handoff":
        poll = [str(script_dir / "poll-handoff.sh"), args.agent, handoff, str(args.max_minutes)]
        if args.handoff_marker:
            poll.append(args.handoff_marker)
    else:
        if (not isinstance(args.task, str) or not args.task.strip()
                or not isinstance(args.handoff_marker, str) or not args.handoff_marker.strip()
                or "\n" in args.task or "\r" in args.task
                or "\n" in args.handoff_marker or "\r" in args.handoff_marker):
            raise ValueError("report polling requires non-empty, single-line --task and --handoff-marker")
        if args.handoff_marker != args.task:
            raise ValueError("report polling requires --handoff-marker equal to --task")
        config_path = str(args.state_root.expanduser().resolve() / args.event / "config.json")
        poll = [str(script_dir / "poll-report.py"), args.agent, handoff,
                config_path, args.handoff_marker, str(args.interval),
                str(args.max_minutes), str(args.idle_grace_seconds)]
    created_at = time.time()
    if args.route is None:
        if not args.thread or any((args.pane, args.terminal_id, args.cwd)):
            raise ValueError("legacy Codex route requires --thread only")
        schema, route_fields = 1, {"thread": args.thread}
    elif args.route == "codex-thread":
        if not args.thread or any((args.pane, args.terminal_id, args.cwd)):
            raise ValueError("Codex route requires --thread only")
        schema = 2
        route_fields = {"destination": {"kind": "codex-thread", "thread": args.thread}}
    else:
        if args.thread or not all((args.pane, args.terminal_id, args.cwd)):
            raise ValueError("Claude route requires --pane, --terminal-id and --cwd, without --thread")
        schema = 2
        route_fields = {"destination": {
            "kind": "claude-pane", "pane": args.pane,
            "terminal_id": args.terminal_id, "cwd": args.cwd,
        }}
    return {
        "schema": schema,
        "event": args.event,
        "task": args.task,
        "agent": args.agent,
        **route_fields,
        "handoff": handoff,
        "handoff_marker": args.handoff_marker,
        "poll": poll,
        "poll_deadline_seconds": args.max_minutes * 60 + (args.interval if args.poll in ("idle", "report") else 60) + 10,
        "created_at": created_at,
        "max_delivery_attempts": args.max_delivery_attempts,
        "initial_backoff_seconds": args.initial_backoff_seconds,
        "typing_retry_seconds": args.typing_retry_seconds,
        "typing_defer_seconds": args.typing_defer_seconds,
        "typing_give_up_seconds": (args.typing_give_up_seconds if args.typing_give_up_seconds is not None
                                   else max(TYPING_GIVE_UP_SECONDS, args.typing_defer_seconds)),
        "attention_after_seconds": args.attention_after_seconds,
    }


def main(argv=None):
    args = _build_parser().parse_args(argv)
    if args.command == "run":
        try:
            print(run_event(args.event_dir), flush=True)
        except Exception as error:
            print(type(error).__name__ + ": " + str(error), file=sys.stderr, flush=True)
            return 1
        return 0
    if args.command == "status":
        lines, attention = listener_status(args.state_root.expanduser())
        for line in lines:
            print(line)
        return 3 if attention else 0
    try:
        config = _config_from_args(args)
        event_dir = args.state_root.expanduser().resolve() / args.event
        result = start_listener(event_dir, config)
    except (DeliveryUncertain, EventIdentityError, ValueError) as error:
        print(type(error).__name__ + ": " + str(error), file=sys.stderr)
        return 2
    print(
        "{} event={} state={} status={} receipt={}".format(
            result,
            args.event,
            event_dir,
            event_dir / "status.json",
            event_dir / "queue-receipt.json",
        )
    )
    return 0


if __name__ == "__main__":
    if len(sys.argv) > 3 and sys.argv[1] == "__poll_supervisor":
        _poll_supervisor(sys.argv[2], sys.argv[3:])
    else:
        raise SystemExit(main())
