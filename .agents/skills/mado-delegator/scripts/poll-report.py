#!/usr/bin/env python3
"""Observe a task-specific report and agent status without reading pane scrollback."""

import json
import subprocess
import sys
import time
from pathlib import Path


def _status(agent):
    result = subprocess.run(
        ["herdr", "agent", "get", agent], capture_output=True, text=True, timeout=20,
    )
    if result.returncode:
        raise RuntimeError("herdr agent get failed: " + (result.stderr.strip() or str(result.returncode)))
    payload = json.loads(result.stdout)
    envelope = payload.get("result") if isinstance(payload, dict) else None
    if not isinstance(envelope, dict) or envelope.get("type") != "agent_info":
        raise ValueError("herdr agent get returned an invalid agent_info envelope")
    record = envelope.get("agent")
    if not isinstance(record, dict) or record.get("name") != agent:
        raise ValueError("herdr agent get returned a missing or mismatched agent identity")
    status = record.get("agent_status")
    if status not in ("working", "idle", "done", "blocked"):
        raise ValueError("unexpected agent_status: " + str(status))
    return status


def _fresh_report(report, created_at, marker):
    return report_evidence(report, created_at, marker) == "ready"


def report_evidence(report, created_at, marker):
    """Require one exact `Report-Task: <task ID>` line in a fresh report."""
    try:
        report = Path(report)
        if not report.is_file():
            return "missing"
        if report.stat().st_mtime < created_at:
            return "stale"
        identities = [line for line in report.read_text(errors="replace").splitlines()
                      if line.startswith("Report-Task:")]
        return "ready" if identities == ["Report-Task: " + marker] else "stale"
    except FileNotFoundError:
        return "missing"


def watch(agent, report, created_at, marker, interval, max_minutes, idle_grace_seconds,
          get_status=_status, sleep=time.sleep, monotonic=time.monotonic):
    report = Path(report)
    started = monotonic()
    idle_since = None
    while True:
        now = monotonic()
        status = get_status(agent)
        if status == "blocked":
            return "blocked"
        if status in ("idle", "done"):
            if _fresh_report(report, created_at, marker):
                return "done"
            if idle_since is None:
                idle_since = now
            if now - idle_since >= idle_grace_seconds:
                return "missing-handoff"
        else:
            idle_since = None
        if now - started >= max_minutes * 60:
            return "timeout"
        sleep(min(interval, max_minutes * 60 - (now - started)))


if __name__ == "__main__":
    agent, path, config_path, marker, seconds, minutes, grace = sys.argv[1:]
    created = json.loads(Path(config_path).read_text())["created_at"]
    outcome = watch(agent, path, float(created), marker, float(seconds), float(minutes), float(grace))
    print(agent + " " + outcome, flush=True)
