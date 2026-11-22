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
    except (OSError, subprocess.TimeoutExpired, UnicodeDecodeError) as exc:
        raise Refused(f"herdr {' '.join(args[:2])} unavailable: {type(exc).__name__}") from exc
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip().replace("\n", " ")[:120]
        raise Refused(f"herdr {' '.join(args[:2])} failed: {detail or result.returncode}")
    return result.stdout


def agent_for(pane, name=None):
    try:
        envelope = json.loads(herdr("agent", "list"))
        if envelope["result"]["type"] != "agent_list":
            raise ValueError("wrong response type")
        agents = envelope["result"]["agents"]
        matches = [agent for agent in agents if agent.get("pane_id") == pane]
        if len(matches) != 1 or matches[0].get("agent") != "codex":
            raise ValueError("expected one Codex agent for pane")
        if name is not None and sum(agent.get("name") == name for agent in agents) > 1:
            raise Refused(f"duplicate or ambiguous agent name {name}")
        return matches[0]
    except (KeyError, TypeError, ValueError) as exc:
        raise Refused(f"agent list has no unambiguous Codex entry for {pane}") from exc


ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")


def normalized_cwd(value):
    if not isinstance(value, str) or not value.strip():
        raise Refused("missing pane cwd")
    path = os.path.expanduser(value.strip())
    if not os.path.isabs(path):
        raise Refused("pane cwd is not absolute")
    return os.path.realpath(path)


def check_cwd(value, source="pane"):
    actual = normalized_cwd(value)
    expected = EXPECTED_SCREEN_CWD if source == "screen" else EXPECTED_CWD
    if actual != expected:
        raise Refused(f"{source} cwd {actual} != expected {expected}")


def pane_screen(pane):
    return ANSI.sub("", herdr("pane", "read", pane, "--source", "recent-unwrapped", "--lines", "2000"))


def screen_state(screen):
    title = screen.rfind(">_ OpenAI Codex (v")
    dialog = screen.rfind("Where should the new conversation run?")
    if dialog > title:
        if "1. Use current Git worktree" not in screen[dialog:]:
            raise Refused("directory dialog has no current-worktree option 1")
        return "dialog"
    new_echo = screen.rfind("/new")
    if title >= 0 and title > new_echo:
        lines = screen[title:].splitlines()
        if len(lines) < 4:
            return "waiting"
        cwd = lines[1].strip()
        footer = next((i for i in range(len(lines) - 1, 1, -1) if "Context 0% used" in lines[i]), -1)
        if footer < 0:
            return "waiting"
        placeholder = "› Ask Codex to do anything"
        body = [line.strip() for line in lines[2:footer] if line.strip()]
        hints = {"? for shortcuts", "? for help", "? for commands", "← for agents · ? for shortcuts"}
        def is_hint(line):
            return line in hints or bool(re.fullmatch(r"(?:← for agents · )?\? for (?:shortcuts|help|commands)\s+⚠\s+\d+ warnings?(?:\s+·\s+f\d+ to view)?", line))
        header = re.compile(r"(?:permissions: .+|model: .+)")
        def logo(line):
            return bool(line) and all(ch.isspace() or "\u2500" <= ch <= "\u259f" or "\u2800" <= ch <= "\u28ff" for ch in line)
        if body.count(placeholder) != 1:
            return "waiting"
        index = body.index(placeholder)
        before = body[:index]
        if sum(line.startswith("Tip:") for line in before) > 1:
            return "submitted"
        if any(not is_hint(line) and not line.startswith("Tip:") and not header.fullmatch(line) and not logo(line) for line in before):
            return "submitted"
        if any(not is_hint(line) for line in body[index + 1:]):
            return "submitted"
        if any(line.strip() and not is_hint(line.strip()) for line in lines[footer + 1:]):
            return "submitted"
        footer_cwd = lines[footer].rsplit("·", 1)[-1].strip()
        check_cwd(cwd, "screen")
        check_cwd(footer_cwd, "screen")
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
    entry = agent_for(pane, name)
    if entry.get("name") != name:
        raise Refused(f"agent name was not restored for {pane}")
    check_cwd(entry.get("cwd"))
    return entry


def composer_has_new(screen):
    # The editable composer is the last prompt line immediately before the current status footer.
    lines = screen.splitlines()
    footer = next((i for i in range(len(lines) - 1, -1, -1) if re.search(r"Context \d+% used", lines[i])), -1)
    if footer < 0:
        return False
    prompt = next((line.strip() for line in reversed(lines[:footer]) if line.strip()), "")
    return prompt == "› /new"


def start(pane, name):
    prior = agent_for(pane)
    if prior.get("agent_status") not in ("idle", "done"):
        raise Refused(f"agent is {prior.get('agent_status')}, not idle")
    check_cwd(prior.get("cwd"))
    before = pane_screen(pane)
    herdr("pane", "send-text", pane, "/new")
    deadline = time.monotonic() + START
    enters = 0
    entered_at = None
    try:
        while time.monotonic() < deadline:
            screen = pane_screen(pane)
            state = screen_state(screen)
            if state == "dialog":
                choose_current_worktree(pane)
                wait_empty(pane, deadline, screen)
                break
            if state == "empty" and screen != before:
                break
            if composer_has_new(screen):
                if enters == 0 or (enters == 1 and "start a new chat during a conversation" in screen and entered_at is not None and time.monotonic() - entered_at >= min(0.5, START / 3)):
                    herdr("pane", "send-keys", pane, "enter")
                    enters += 1
                    entered_at = time.monotonic()
            time.sleep(POLL)
        else:
            raise Refused("fresh directory dialog or empty Codex prompt never appeared")
    except Refused:
        # A failed dispatch must not leave /new in the editable composer.
        if composer_has_new(pane_screen(pane)):
            herdr("pane", "send-keys", pane, "ctrl+u")
        raise
    restore_name(pane, name)


def wait_working(pane, name):
    deadline = time.monotonic() + CONFIRM
    while time.monotonic() < deadline:
        entry = agent_for(pane, name)
        if entry.get("name") != name:
            raise Refused("agent name was lost after prompting")
        check_cwd(entry.get("cwd"))
        if entry.get("agent_status") == "working":
            return True
        time.sleep(POLL)
    return False


def prompt_and_confirm(pane, name, prompt):
    if not prompt.strip():
        raise Refused("empty task prompt")
    check_cwd(agent_for(pane).get("cwd"))
    entry = restore_name(pane, name)
    if entry.get("agent_status") not in ("idle", "done"):
        raise Refused(f"agent is {entry.get('agent_status')}, not idle")
    screen = pane_screen(pane)
    state = screen_state(screen)
    if state == "dialog":
        choose_current_worktree(pane)
        wait_empty(pane, time.monotonic() + START, screen)
        restore_name(pane, name)
    elif state != "empty":
        raise Refused("fresh Codex prompt is not empty")
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
            raise Refused("prompt was submitted but agent did not reach working")
    raise Refused("agent never reached working after two prompt attempts")


try:
    START = timer("MADO_FRESH_START_SECS", "45")
    CONFIRM = timer("MADO_FRESH_CONFIRM_SECS", "20")
    POLL = timer("MADO_FRESH_POLL_SECS", "0.25")
    args = sys.argv[1:]
    if args and args[0] == "prompt-and-confirm":
        if len(args) == 6 and args[3] == "--cwd":
            _, pane, name, _, expected, prompt = args
            screen_expected = expected
        elif len(args) == 8 and args[3] == "--cwd" and args[5] == "--screen-cwd":
            _, pane, name, _, expected, _, screen_expected, prompt = args
        else:
            raise Refused("invalid prompt-and-confirm arguments")
        start_mode = False
    elif len(args) == 4 and args[2] == "--cwd":
        pane, name, _, expected = args
        screen_expected = expected
        prompt = None
        start_mode = True
    elif len(args) == 6 and args[2] == "--cwd" and args[4] == "--prompt":
        pane, name, _, expected, _, prompt = args
        screen_expected = expected
        start_mode = True
    elif len(args) in (6, 8) and args[2] == "--cwd" and args[4] == "--screen-cwd" and (len(args) == 6 or args[6] == "--prompt"):
        pane, name, _, expected, _, screen_expected = args[:6]
        prompt = args[7] if len(args) == 8 else None
        start_mode = True
    else:
        raise Refused("usage: start-fresh-codex.sh <pane> <agent-name> --cwd <worktree> [--prompt <text>] | prompt-and-confirm <pane> <agent-name> --cwd <worktree> <text>")
    if not re.fullmatch(r"w[0-9]+:p[A-Za-z0-9]+", pane) or not re.fullmatch(r"[a-z][a-z0-9-]+", name):
        raise Refused("invalid pane or agent name")
    EXPECTED_CWD = normalized_cwd(expected)
    EXPECTED_SCREEN_CWD = normalized_cwd(screen_expected)
    if prompt is not None and prompt.startswith("-"):
        raise Refused("task prompt starts with -; herdr agent prompt has no safe option-like text argument")
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
