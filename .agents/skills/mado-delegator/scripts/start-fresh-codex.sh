#!/bin/bash
# Start a fresh Codex pane and confirm that its first task actually starts (#804).
exec python3 - "$@" <<'PY'
import json
import os
import re
import subprocess
import sys
import time


class Refused(Exception):
    pass


def timer(name, default):
    raw = os.environ.get(name, default)
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+)?", raw):
        raise Refused(f"invalid {name}")
    value = float(raw)
    if not 0 < value <= 300:
        raise Refused(f"invalid {name}")
    return value


def herdr(*args):
    try:
        result = subprocess.run(["herdr", *args], text=True, capture_output=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise Refused(f"herdr {' '.join(args[:2])} unavailable: {type(exc).__name__}") from exc
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip().replace("\n", " ")[:120]
        raise Refused(f"herdr {' '.join(args[:2])} failed: {detail or result.returncode}")
    return result.stdout


def agent_for(pane):
    try:
        envelope = json.loads(herdr("agent", "list"))
        if envelope["result"]["type"] != "agent_list":
            raise ValueError("wrong response type")
        matches = [agent for agent in envelope["result"]["agents"] if agent.get("pane_id") == pane]
        if len(matches) != 1 or matches[0].get("agent") != "codex":
            raise ValueError("expected one Codex agent for pane")
        return matches[0]
    except (KeyError, TypeError, ValueError) as exc:
        raise Refused(f"agent list has no unambiguous Codex entry for {pane}") from exc


ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")


def pane_screen(pane):
    return ANSI.sub("", herdr("pane", "read", pane, "--source", "recent-unwrapped", "--lines", "2000"))


def screen_state(screen):
    title = screen.rfind(">_ OpenAI Codex (v")
    dialog = screen.rfind("Where should the new conversation run?")
    if dialog > title:
        if "1. Use current Git worktree" not in screen[dialog:]:
            raise Refused("directory dialog has no current-worktree option 1")
        return "dialog"
    placeholder = screen.rfind("› Ask Codex to do anything")
    context = screen.rfind("Context 0% used")
    new_echo = screen.rfind("/new")
    if title >= 0 and title > new_echo and placeholder > title and context > placeholder:
        return "empty"
    return "waiting"


def choose_current_worktree(pane):
    herdr("pane", "send-keys", pane, "1")
    herdr("pane", "send-keys", pane, "enter")


def wait_empty(pane, deadline, previous=""):
    while time.monotonic() < deadline:
        screen = pane_screen(pane)
        state = screen_state(screen)
        if state == "empty" and screen != previous:
            return
        time.sleep(POLL)
    raise Refused("directory dialog did not close to an empty Codex prompt")


def restore_name(pane, name):
    herdr("agent", "rename", pane, name)
    herdr("pane", "rename", pane, name)
    entry = agent_for(pane)
    if entry.get("name") != name:
        raise Refused(f"agent name was not restored for {pane}")
    return entry


def start(pane, name):
    prior = agent_for(pane)
    if prior.get("agent_status") not in ("idle", "done"):
        raise Refused(f"agent is {prior.get('agent_status')}, not idle")
    before = pane_screen(pane)
    herdr("pane", "send-text", pane, "/new")
    herdr("pane", "send-keys", pane, "enter")
    started = time.monotonic()
    deadline = started + START
    submitted_again = False
    while time.monotonic() < deadline:
        screen = pane_screen(pane)
        state = screen_state(screen)
        if state == "dialog":
            choose_current_worktree(pane)
            wait_empty(pane, deadline, screen)
            break
        if state == "empty" and screen != before:
            break
        if not submitted_again and time.monotonic() - started >= min(2.0, START / 2):
            herdr("pane", "send-keys", pane, "enter")
            submitted_again = True
        time.sleep(POLL)
    else:
        raise Refused("fresh directory dialog or empty Codex prompt never appeared")
    restore_name(pane, name)


def wait_working(pane, name):
    deadline = time.monotonic() + CONFIRM
    while time.monotonic() < deadline:
        entry = agent_for(pane)
        if entry.get("name") != name:
            raise Refused("agent name was lost after prompting")
        if entry.get("agent_status") == "working":
            return True
        time.sleep(POLL)
    return False


def prompt_and_confirm(pane, name, prompt):
    if not prompt.strip():
        raise Refused("empty task prompt")
    entry = restore_name(pane, name)
    if entry.get("agent_status") not in ("idle", "done"):
        raise Refused(f"agent is {entry.get('agent_status')}, not idle")
    screen = pane_screen(pane)
    if screen_state(screen) == "dialog":
        choose_current_worktree(pane)
        wait_empty(pane, time.monotonic() + START, screen)
        restore_name(pane, name)
    for attempt in (1, 2):
        herdr("agent", "prompt", name, prompt)
        if wait_working(pane, name):
            return
        if attempt == 2:
            break
        screen = pane_screen(pane)
        state = screen_state(screen)
        if state == "dialog":
            choose_current_worktree(pane)
            wait_empty(pane, time.monotonic() + START, screen)
            restore_name(pane, name)
        elif state != "empty":
            raise Refused("prompt did not start; pane is neither dialog nor empty prompt")
    raise Refused("agent never reached working after two prompt attempts")


try:
    START = timer("MADO_FRESH_START_SECS", "45")
    CONFIRM = timer("MADO_FRESH_CONFIRM_SECS", "20")
    POLL = timer("MADO_FRESH_POLL_SECS", "0.25")
    args = sys.argv[1:]
    if len(args) == 4 and args[0] == "prompt-and-confirm":
        _, pane, name, prompt = args
        start_mode = False
    elif len(args) == 2:
        pane, name = args
        prompt = None
        start_mode = True
    elif len(args) == 4 and args[2] == "--prompt":
        pane, name, _, prompt = args
        start_mode = True
    else:
        raise Refused("usage: start-fresh-codex.sh <pane> <agent-name> [--prompt <text>] | prompt-and-confirm <pane> <agent-name> <text>")
    if not re.fullmatch(r"w[0-9]+:p[A-Za-z0-9]+", pane) or not re.fullmatch(r"[a-z][a-z0-9-]+", name):
        raise Refused("invalid pane or agent name")
    if start_mode:
        start(pane, name)
    if prompt is not None:
        prompt_and_confirm(pane, name, prompt)
        print(f"fresh Codex {name} working in {pane}")
    else:
        print(f"fresh Codex {name} ready in {pane}; prompt-and-confirm required")
except Refused as exc:
    print(f"FAIL start-fresh-codex: {str(exc).replace(chr(10), ' ')}", file=sys.stderr)
    sys.exit(1)
PY
