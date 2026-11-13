import importlib.util
import json
import os
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
from pathlib import Path


SCRIPT = Path(__file__).with_name("listen-notify.py")
SPEC = importlib.util.spec_from_file_location("listen_notify", SCRIPT)
listen_notify = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(listen_notify)
REPORT_SCRIPT = Path(__file__).with_name("poll-report.py")
REPORT_SPEC = importlib.util.spec_from_file_location("poll_report", REPORT_SCRIPT)
poll_report = importlib.util.module_from_spec(REPORT_SPEC)
REPORT_SPEC.loader.exec_module(poll_report)
# Shapes copied from `herdr pane read --source visible --format ansi` on live Claude Code panes (2026-10-25).
GREY = "\x1b[0m\x1b[38;2;136;136;136m"
EMPTY_BOX = "❯\xa0"
BUSY_EMPTY_BOX = "\x1b[0m\x1b[38;2;153;153;153m❯\xa0\x1b[0m"
TYPED_BOX = "\x1b[0m\x1b[38;2;153;153;153m❯\xa0\x1b[0mhalf-typed message"
SUGGESTION_BOX = "❯\xa0\x1b[0m\x1b[2m把 README 和 AGENTS.md 的改动开个 PR\x1b[0m"
READ_ARGV = ["herdr", "pane", "read", "w1:p1", "--source", "visible", "--format", "ansi"]
# Whole visible reads saved from live panes on 2026-10-26 (#157): a scratch Claude Code 2.1.310 pane,
# the delegator pane w1:p1 (read only) and the short opus-imple-1 pane w1:p9. Per-machine names are placeholders.
SCREENS = Path(__file__).with_name("fixtures") / "claude-screens"
DIALOG_SCREEN = (SCREENS / "dialog-ask-one.ansi").read_text()


def claude_screen(*box, label=" picsee-delegator ─"):
    lines = ["✻ Crunched for 2m 3s · done 11:14 PM",
             " " * 80 + "✘ Auto-update failed · Run claude doctor",
             GREY + "─" * 100 + label + "\x1b[0m", *box, GREY + "─" * 120 + "\x1b[0m",
             "  ⚠ picsee-timeline: ⏭ P2-05 · ◆ P0 已齐", "  [Opus 5.5] │ picsee git:(main*)",
             "  Context ███░░░░░░░ 33% │ Usage █░░░░░░░░░ 7%", "  ⏵⏵ auto mode on (shift+tab to cycle)"]
    return "\r\n".join(lines) + "\r\n"


class LockAlertStatusTests(unittest.TestCase):
    """#672: heavy-lock budget alerts beside the listeners directory need the delegator."""

    def test_open_lock_alerts_are_attention_until_acknowledged(self):
        with tempfile.TemporaryDirectory() as temporary:
            delegator = Path(temporary)
            listeners = delegator / "listeners"
            listeners.mkdir()
            self.assertEqual(listen_notify.listener_status(listeners), ([], False))
            alerts = delegator / "lock-alerts"
            (alerts / "acked").mkdir(parents=True)
            record = {"id": "a" * 32, "phase": "cleanup", "cleanup": "incomplete",
                      "budgetSeconds": 600, "pid": 41, "pgid": 41}
            (alerts / "acked" / "old.json").write_text(json.dumps(record))
            self.assertEqual(listen_notify.listener_status(listeners), ([], False))
            (alerts / ("a" * 32 + ".json")).write_text(json.dumps(record))
            (alerts / "broken.json").write_text("{")
            lines, attention = listen_notify.listener_status(listeners)
            self.assertTrue(attention)
            self.assertEqual(lines, [
                "attention lock-alert {} phase=cleanup cleanup=incomplete budget=600s pid=41 pgid=41 file={}".format(
                    "a" * 32, alerts / ("a" * 32 + ".json")),
                "attention lock-alert broken state=invalid file={}".format(alerts / "broken.json"),
            ])


class ListenerTests(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.root = Path(self.temporary_directory.name)
        self.handoff = self.root / "issue90-handoff.md"
        self.config = {
            "schema": 1,
            "event": "issue90-round-1-head-deadbee",
            "task": "issue90-round-1",
            "agent": "gpt-imple-3",
            "thread": "11111111-2222-4333-8444-555555555555",
            "handoff": str(self.handoff),
            "poll": ["/skill/scripts/poll-idle.sh", "gpt-imple-3", "120", "3000"],
            "created_at": 1_800_000_000.0,
            "max_delivery_attempts": 3,
            "initial_backoff_seconds": 1,
        }
        self.event_dir = self.root / "events" / self.config["event"]
        self.event_dir.mkdir(parents=True)
        (self.event_dir / "config.json").write_text(json.dumps(self.config))

    @staticmethod
    def completed(argv, returncode=0, stdout="", stderr=""):
        return subprocess.CompletedProcess(argv, returncode, stdout, stderr)

    def test_status_reads_real_herdr_envelope_and_rejects_wrong_agent(self):
        for status in ("working", "idle", "done", "blocked"):
            payload = {"id": "cli:agent:get", "result": {"type": "agent_info",
                       "agent": {"name": "gpt-auditor", "agent_status": status}}}
            with self.subTest(status=status), patch.object(poll_report.subprocess, "run",
                    return_value=self.completed([], stdout=json.dumps(payload))):
                try:
                    observed = poll_report._status("gpt-auditor")
                except Exception as error:
                    observed = type(error).__name__
                self.assertEqual(observed, status)
        payload["result"]["agent"]["name"] = "other-agent"
        with patch.object(poll_report.subprocess, "run",
                return_value=self.completed([], stdout=json.dumps(payload))):
            with self.assertRaises(ValueError):
                poll_report._status("gpt-auditor")

    def test_status_rejects_malformed_envelopes(self):
        for payload in ({}, {"agent_status": "idle"}, {"result": []},
                        {"result": {"type": "error", "agent": {"name": "gpt-auditor", "agent_status": "idle"}}},
                        {"result": {"type": "agent_info", "agent": {"name": "gpt-auditor", "agent_status": "unknown"}}},
                        {"result": {"type": "agent_info", "agent": {"agent_status": "idle"}}}):
            with self.subTest(payload=payload), patch.object(poll_report.subprocess, "run",
                    return_value=self.completed([], stdout=json.dumps(payload))):
                with self.assertRaises(ValueError):
                    poll_report._status("gpt-auditor")

    def test_routes_to_exact_thread_and_successful_repeat_does_not_queue_again(self):
        self.handoff.write_text("DONE\n")
        os.utime(self.handoff, (1_800_000_001, 1_800_000_001))
        calls = []

        def run(argv, **kwargs):
            calls.append((argv, kwargs))
            if argv[0] == "/skill/scripts/poll-idle.sh":
                return self.completed(argv, stdout="gpt-imple-3 idle 12:00:00\n")
            return self.completed(argv, stdout='{"queued":true,"id":"q-1"}\n')

        self.assertEqual(listen_notify.run_event(self.event_dir, run=run), "delivered")
        self.assertEqual(listen_notify.run_event(self.event_dir, run=run), "already-delivered")

        queue_calls = [call for call in calls if call[0][0:2] == ["codex", "queue"]]
        self.assertEqual(len(queue_calls), 1)
        self.assertEqual(
            queue_calls[0][0][0:4],
            ["codex", "queue", "--thread", self.config["thread"]],
        )
        self.assertIn("--message", queue_calls[0][0])
        message = queue_calls[0][0][-1]
        self.assertIn(self.config["event"], message)
        self.assertIn(str(self.handoff), message)
        self.assertIn("poll completion is not audit acceptance", message.lower())
        receipt = json.loads((self.event_dir / "queue-receipt.json").read_text())
        self.assertEqual(receipt["event"], self.config["event"])
        self.assertEqual(receipt["queue_response"], '{"queued":true,"id":"q-1"}')

    def claude_config(self):
        config = dict(self.config)
        config.pop("thread")
        config["schema"] = 2
        config["destination"] = {
            "kind": "claude-pane", "pane": "w1:p1",
            "terminal_id": "term_123abc", "cwd": "/tmp/picsee",
        }
        (self.event_dir / "config.json").write_text(json.dumps(config))
        (self.event_dir / "poll-result.json").write_text(json.dumps({
            "outcome": "done", "exit_code": 0, "handoff_evidence": "ready",
        }))
        return config

    def pane_list(self, *, pane="w1:p1", agent="claude", terminal="term_123abc",
                  cwd="/tmp/picsee", foreground=None):
        return {"id": "cli:pane:list", "result": {"type": "pane_list", "panes": [{
            "pane_id": pane, "agent": agent, "terminal_id": terminal,
            "cwd": cwd, "foreground_cwd": cwd if foreground is None else foreground,
        }]}}

    @staticmethod
    def fake_clock(call_seconds=0):
        """Monotonic clock that advances on sleep and, optionally, on every herdr call."""
        now = [0.0]
        sleeps = []

        def sleep(seconds):
            sleeps.append(seconds)
            now[0] += seconds

        def timed(run):
            def wrapped(argv, **kwargs):
                now[0] += call_seconds
                return run(argv, **kwargs)
            return wrapped

        return (lambda: now[0]), sleep, sleeps, timed

    def claude_transport(self, screens, calls, on_read=None):
        """Fake herdr: pane list matches, pane read returns `screens` in turn (last one repeats), run succeeds."""
        screens = list(screens)

        def run(argv, **_):
            calls.append(argv)
            if argv == ["herdr", "pane", "list"]:
                return self.completed(argv, stdout=json.dumps(self.pane_list()))
            if argv[:3] == ["herdr", "pane", "read"]:
                self.assertEqual(argv, READ_ARGV)
                if on_read:
                    on_read()
                return self.completed(argv, stdout=screens.pop(0) if len(screens) > 1 else screens[0])
            self.assertEqual(argv[:4], ["herdr", "pane", "run", "w1:p1"])
            return self.completed(argv)

        return run

    def test_claude_route_checks_pane_then_sends_once_with_receipt(self):
        config = self.claude_config()
        calls = []

        def run(argv, **_):
            calls.append(argv)
            if argv == ["herdr", "pane", "list"]:
                return self.completed(argv, stdout=json.dumps(self.pane_list()))
            if argv[:3] == ["herdr", "pane", "read"]:
                self.assertEqual(argv, READ_ARGV)
                return self.completed(argv, stdout=claude_screen(EMPTY_BOX))
            self.assertEqual(argv[:4], ["herdr", "pane", "run", "w1:p1"])
            self.assertEqual(argv[4], ": PICSEE_LISTENER_EVENT_" + config["event"])
            return self.completed(argv)

        self.assertEqual(listen_notify.run_event(self.event_dir, run=run), "delivered")
        self.assertEqual(listen_notify.run_event(self.event_dir, run=run), "already-delivered")
        self.assertEqual([call[:3] for call in calls],
                         [["herdr", "pane", "list"], ["herdr", "pane", "read"], ["herdr", "pane", "read"],
                          ["herdr", "pane", "run"], ["herdr", "pane", "list"]])
        receipt = json.loads((self.event_dir / "queue-receipt.json").read_text())
        self.assertEqual(receipt["destination"], config["destination"])
        self.assertNotIn("thread", receipt)
        self.assertIn(config["event"], (self.event_dir / "notification.txt").read_text())
        self.assertIn(str(self.handoff), (self.event_dir / "notification.txt").read_text())
        self.assertNotIn(str(self.handoff), calls[3][4])

    def test_claude_route_refuses_stale_or_malformed_pane_before_send(self):
        config = self.claude_config()
        config["max_delivery_attempts"] = 1
        (self.event_dir / "config.json").write_text(json.dumps(config))
        bad = [
            self.pane_list(pane="w1:p8"),
            self.pane_list(agent="codex"),
            self.pane_list(terminal="term_replaced"),
            self.pane_list(cwd="/tmp/other"),
            self.pane_list(foreground="/tmp/other"),
            {"id": "cli:pane:list", "result": {"panes": []}},
            {"id": "cli:pane:list", "result": {"type": "pane_list", "panes": [
                self.pane_list()["result"]["panes"][0],
                self.pane_list()["result"]["panes"][0],
            ]}},
            {"error": {"code": "offline"}, "id": "cli:pane:list"},
        ]
        for payload in bad:
            with self.subTest(payload=payload):
                (self.event_dir / "queue-receipt.json").unlink(missing_ok=True)
                calls = []

                def run(argv, **_):
                    calls.append(argv)
                    return self.completed(argv, stdout=json.dumps(payload))

                with self.assertRaises(listen_notify.DeliveryError):
                    listen_notify.run_event(self.event_dir, run=run, sleep=lambda _: None)
                self.assertEqual(calls, [["herdr", "pane", "list"]])
                self.assertFalse((self.event_dir / "queue-receipt.json").exists())

    def test_claude_route_requires_acknowledged_run(self):
        self.claude_config()
        calls = []

        def run(argv, **_):
            calls.append(argv)
            if argv == ["herdr", "pane", "list"]:
                return self.completed(argv, stdout=json.dumps(self.pane_list()))
            if argv[:3] == ["herdr", "pane", "read"]:
                return self.completed(argv, stdout=claude_screen(EMPTY_BOX))
            return self.completed(argv, stdout=json.dumps({
                "id": "cli:pane:run", "error": {"code": "pane_replaced"},
            }))

        with self.assertRaises(listen_notify.DeliveryUncertain):
            listen_notify.run_event(self.event_dir, run=run, sleep=lambda _: None)
        self.assertFalse((self.event_dir / "queue-receipt.json").exists())
        self.assertEqual(sum(x[:3] == ["herdr", "pane", "run"] for x in calls), 1)

    def test_claude_uses_observed_herdr_success_contract_only(self):
        self.assertTrue(listen_notify._accepted_claude_run(self.completed([])))
        self.assertFalse(listen_notify._accepted_claude_run(self.completed(
            [], returncode=1, stdout=json.dumps({
                "error": {"code": "pane_not_found"}, "id": "cli:request",
            }))))
        self.assertFalse(listen_notify._accepted_claude_run(self.completed(
            [], stdout=json.dumps({"id": "cli:pane:run", "result": {"success": True}}))))
        self.assertFalse(listen_notify._accepted_claude_run(self.completed(
            [], stderr="unexpected diagnostic")))

    def test_claude_lost_response_never_replays(self):
        self.claude_config()
        calls = []

        def run(argv, **_):
            calls.append(argv)
            if argv == ["herdr", "pane", "list"]:
                return self.completed(argv, stdout=json.dumps(self.pane_list()))
            if argv[:3] == ["herdr", "pane", "read"]:
                return self.completed(argv, stdout=claude_screen(EMPTY_BOX))
            raise subprocess.TimeoutExpired(argv, 30)

        with self.assertRaises(listen_notify.DeliveryUncertain):
            listen_notify.run_event(self.event_dir, run=run, sleep=lambda _: None)
        self.assertFalse((self.event_dir / "queue-receipt.json").exists())
        self.assertEqual(json.loads((self.event_dir / "status.json").read_text())["state"],
                         "delivery-uncertain")
        with self.assertRaises(listen_notify.DeliveryUncertain):
            listen_notify.run_event(self.event_dir, run=run)
        self.assertEqual(sum(x[:3] == ["herdr", "pane", "run"] for x in calls), 1)
        with self.assertRaises(listen_notify.DeliveryUncertain):
            listen_notify.start_listener(self.event_dir, json.loads(
                (self.event_dir / "config.json").read_text()), launch=lambda *_a, **_k: self.fail("replayed"))

    def test_claude_pane_replaced_after_send_has_no_receipt(self):
        self.claude_config()
        calls = []

        def run(argv, **_):
            calls.append(argv)
            if argv == ["herdr", "pane", "list"]:
                terminal = "term_123abc" if len(calls) == 1 else "term_replacement"
                return self.completed(argv, stdout=json.dumps(self.pane_list(terminal=terminal)))
            if argv[:3] == ["herdr", "pane", "read"]:
                return self.completed(argv, stdout=claude_screen(EMPTY_BOX))
            return self.completed(argv)

        with self.assertRaises(listen_notify.DeliveryUncertain):
            listen_notify.run_event(self.event_dir, run=run, sleep=lambda _: None)
        self.assertEqual(len(calls), 5)
        self.assertFalse((self.event_dir / "queue-receipt.json").exists())

    def test_claude_input_box_classifier_reads_only_undimmed_text_inside_the_box(self):
        state = listen_notify._claude_input_state
        for screen in (claude_screen(EMPTY_BOX), claude_screen(BUSY_EMPTY_BOX),
                       claude_screen("❯ "), claude_screen(SUGGESTION_BOX),
                       claude_screen(EMPTY_BOX, label=""),
                       claude_screen("❯\xa0\x1b[2;38:5:244msuggestion\x1b[0m"),
                       claude_screen("❯\xa0\x1b[2;38;2;1;2;3;1msuggestion\x1b[39;22m")):
            with self.subTest(screen=screen):
                self.assertEqual(state(screen), "empty")
        for screen in (claude_screen(TYPED_BOX), claude_screen("❯\xa0x"),
                       claude_screen(EMPTY_BOX, "  second line typed"),
                       claude_screen("❯\xa0\x1b[2msuggestion\x1b[22m typed after"),
                       claude_screen("❯\xa0\x1b[2m\x1b[0mtyped after reset"),
                       claude_screen("❯\xa0[Pasted text #1 +5 lines]"),
                       claude_screen("❯\xa0\x1b[38;2;2;2;2mcoloured typed"),
                       claude_screen("❯\xa0\x1b[2m", "\x1b[0m  typed on a dim-reset line"),
                       # Encodings not positively recognised as the dim suggestion count as typed text.
                       claude_screen("❯\xa0\x1b[38:2::255:0:2mtyped"),
                       claude_screen("❯\xa0\x1b[2msugg\x1b[00mtyped"),
                       claude_screen("❯\xa0\x1b[2msugg\x1b[4:3mtyped"),
                       claude_screen("❯\xa0\x1b[2msugg\x1b[99mtyped"),
                       claude_screen("❯\xa0\x1b[2msugg\x1b[38;2;1mtyped"),
                       claude_screen("❯\xa0\x1b[2msugg\x1b[?2mtyped"),
                       claude_screen("❯\xa0\x1b[2msugg\x1b[2 mtyped")):
            with self.subTest(screen=screen):
                self.assertEqual(state(screen), "typing")
        for screen in ("", "plain shell $ \r\n", claude_screen("! ls"),
                       claude_screen(EMPTY_BOX).split(GREY + "─" * 120)[0],
                       "Back to bottom; older activity\r\n" + GREY + "─" * 100 + "\x1b[0m\r\n",
                       claude_screen("  1. Yes", "❯ 2. No")):
            with self.subTest(screen=screen):
                self.assertEqual(state(screen), "unknown")

    def test_claude_input_classifier_on_captured_live_screens(self):
        expected = {
            "idle-fresh": "empty", "idle-long-message": "empty", "idle-after-dialog": "empty",
            "idle-delegator-suggestion": "empty", "typing-short": "typing",
            # An open AskUserQuestion or trust dialog is recognised, and held like typing.
            "dialog-ask-one": "dialog", "dialog-ask-two": "dialog", "dialog-ask-two-typed": "dialog",
            "dialog-trust-folder": "dialog",
            # A pane too short to show the box stays unknown.
            "unknown-short-viewport": "unknown",
        }
        self.assertEqual(sorted(path.stem for path in SCREENS.glob("*.ansi")), sorted(expected))
        for name, state in expected.items():
            with self.subTest(screen=name):
                self.assertEqual(listen_notify._claude_input_state((SCREENS / (name + ".ansi")).read_text()), state)
        # The footer must be the last line drawn: one quoted in the conversation above a live box is not a dialog.
        quoted = claude_screen(EMPTY_BOX).replace(
            "✻ Crunched", "Enter to select · ↑/↓ to navigate · Esc to cancel\r\n✻ Crunched")
        self.assertEqual(listen_notify._claude_input_state(quoted), "empty")
        self.assertEqual(listen_notify._claude_input_state(
            claude_screen(TYPED_BOX) + "  Enter to select · ↑/↓ to navigate · Esc to cancel"), "dialog")
        for footer in ("Enter to select", "Press Enter to select · Esc to cancel", "Esc to cancel"):
            with self.subTest(footer=footer):
                self.assertEqual(listen_notify._claude_input_state("─" * 40 + "\r\n" + footer), "unknown")
        # A conversation line identical to the footer, with the box scrolled out of view, is not a dialog:
        # a dialog also needs a rule above it and a selection cursor below that rule.
        footer = "Enter to select · ↑/↓ to navigate · Esc to cancel"
        for screen in ("⏺ The dialog footer reads:\r\n  " + footer + "\r\n",
                       "❯ quote the footer\r\n⏺ Here it is:\r\n  " + footer + "\r\n",
                       "❯ quote the footer\r\n" + "─" * 40 + "\r\n  1. Red\r\n" + footer + "\r\n"):
            with self.subTest(screen=screen):
                self.assertEqual(listen_notify._claude_input_state(screen), "unknown")

    def test_claude_first_unreadable_screen_is_saved_once_per_run_and_bounded(self):
        config = self.claude_config()
        config.update(typing_retry_seconds=5, typing_defer_seconds=10, typing_give_up_seconds=10)
        (self.event_dir / "config.json").write_text(json.dumps(config))
        first = "\x1b[1mfirst unreadable\x1b[0m\r\n" + "─" * 40 + "\r\n! ls\r\n" + "─" * 40 + "\r\n"
        clock, sleep, _, _ = self.fake_clock()
        run = self.claude_transport([first, "later unreadable"], [])
        with self.assertRaises(listen_notify.DeliveryDeferred):
            listen_notify.run_event(self.event_dir, run=run, sleep=sleep, clock=clock)
        self.assertEqual((self.event_dir / "input-snapshot.ansi").read_bytes().decode(), first)
        snapshot = json.loads((self.event_dir / "input-snapshot.json").read_text())
        self.assertEqual(snapshot["input"], "unknown")
        self.assertEqual(snapshot["pane"], "w1:p1")
        self.assertEqual(snapshot["truncated"], False)
        self.assertEqual(snapshot["lines"], ["first unreadable", "─" * 40, "! ls", "─" * 40, ""])
        self.assertEqual(snapshot["rules"], [1, 3])
        self.assertEqual(snapshot["box"], ["! ls"])
        self.assertIsInstance(snapshot["captured_at"], str)

        # A later run overwrites it, keeping only the tail of a huge read (the box is at the bottom).
        (self.event_dir / "status.json").unlink()
        # Both files are bounded in bytes: wide characters take three bytes each.
        huge = "界" * 100_000 + "\r\n" + "tail line"
        clock, sleep, _, _ = self.fake_clock()
        with self.assertRaises(listen_notify.DeliveryDeferred):
            listen_notify.run_event(self.event_dir, run=self.claude_transport([huge], []), sleep=sleep, clock=clock)
        saved = (self.event_dir / "input-snapshot.ansi").read_bytes()
        self.assertLessEqual(len(saved), listen_notify.SNAPSHOT_BYTES)
        self.assertGreater(len(saved), listen_notify.SNAPSHOT_BYTES - 3)
        self.assertTrue(saved.decode().endswith("tail line"))
        self.assertLessEqual(len((self.event_dir / "input-snapshot.json").read_bytes()), listen_notify.SNAPSHOT_BYTES)
        snapshot = json.loads((self.event_dir / "input-snapshot.json").read_text())
        self.assertEqual(snapshot["truncated"], True)
        self.assertLessEqual(len(snapshot["lines"]), listen_notify.SNAPSHOT_LINES)
        self.assertEqual(snapshot["lines"][-1], "tail line")

        # An oversized unreadable box is cut to the same bound; what is kept is the tail of `lines`.
        for box in ("! " + "y" * 200_000, "\r\n".join("! line {} ".format(n) + "z" * 2000 for n in range(150))):
            with self.subTest(box=box[:12]):
                (self.event_dir / "status.json").unlink()
                screen = "─" * 40 + "\r\n" + box + "\r\n" + "─" * 40 + "\r\nfooter"
                clock, sleep, _, _ = self.fake_clock()
                with self.assertRaises(listen_notify.DeliveryDeferred):
                    listen_notify.run_event(self.event_dir, run=self.claude_transport([screen], []),
                                            sleep=sleep, clock=clock)
                encoded = (self.event_dir / "input-snapshot.json").read_bytes()
                self.assertLessEqual(len(encoded), listen_notify.SNAPSHOT_BYTES)
                snapshot = json.loads(encoded)
                self.assertEqual(snapshot["truncated"], True)
                self.assertEqual(snapshot["lines"][-1], "footer")
                kept = snapshot["lines"]
                self.assertEqual(snapshot["rules"][-1], len(kept) - 2)
                self.assertTrue(all(kept[index] == "─" * 40 for index in snapshot["rules"]))
                self.assertEqual(kept[len(kept) - 2 - len(snapshot["box"]):len(kept) - 2], snapshot["box"])

        # Typed text and a recognised dialog are not saved.
        for screen in (claude_screen(TYPED_BOX), DIALOG_SCREEN):
            with self.subTest(screen=screen[:20]):
                for name in ("status.json", "input-snapshot.ansi", "input-snapshot.json"):
                    (self.event_dir / name).unlink(missing_ok=True)
                clock, sleep, _, _ = self.fake_clock()
                with self.assertRaises(listen_notify.DeliveryDeferred):
                    listen_notify.run_event(self.event_dir, run=self.claude_transport([screen], []),
                                            sleep=sleep, clock=clock)
                self.assertFalse((self.event_dir / "input-snapshot.ansi").exists())
                self.assertFalse((self.event_dir / "input-snapshot.json").exists())

    def test_claude_stuck_unreadable_or_dialog_hold_writes_one_attention_line(self):
        config = self.claude_config()
        config.update(typing_retry_seconds=5, typing_defer_seconds=60, typing_give_up_seconds=120,
                      attention_after_seconds=30)
        (self.event_dir / "config.json").write_text(json.dumps(config))
        attention_log = self.root / "attention.log"
        for screen, reason in ((DIALOG_SCREEN, "dialog"), ("unparseable", "unknown")):
            with self.subTest(reason=reason):
                attention_log.unlink(missing_ok=True)
                (self.event_dir / "status.json").unlink(missing_ok=True)
                clock, advance, _, _ = self.fake_clock()
                states = []

                def sleep(seconds):
                    states.append(json.loads((self.event_dir / "status.json").read_text()))
                    advance(seconds)

                with self.assertRaises(listen_notify.DeliveryDeferred):
                    listen_notify.run_event(self.event_dir, run=self.claude_transport([screen], []),
                                            sleep=sleep, clock=clock)
                lines = attention_log.read_text().splitlines()
                self.assertEqual(len(lines), 1)
                self.assertRegex(lines[0], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ ")
                for part in ("listener " + config["event"], "input=" + reason, "held 30s",
                             "pane w1:p1", "listen-notify.py status"):
                    self.assertIn(part, lines[0])
                # From the alert on, status.json carries the flag, so `status` exits 3 while still waiting.
                waiting = [s for s in states if s["state"] == "waiting-user-typing"]
                self.assertEqual([s.get("attention", False) for s in waiting], [False] * 6 + [True] * 6)
                self.assertTrue(json.loads((self.event_dir / "status.json").read_text())["attention"])
                (self.event_dir / "pid").write_text(str(os.getpid()) + "\n")
                lines, attention = listen_notify.listener_status(self.event_dir.parent)
                self.assertTrue(attention)
                self.assertTrue(lines[0].startswith("attention " + config["event"]))
                self.assertIn("input=" + reason, lines[0])

        # Typing is a person at the box: it is held without an attention line.
        attention_log.unlink()
        (self.event_dir / "status.json").unlink()
        clock, sleep, _, _ = self.fake_clock()
        with self.assertRaises(listen_notify.DeliveryDeferred):
            listen_notify.run_event(self.event_dir, run=self.claude_transport([claude_screen(TYPED_BOX)], []),
                                    sleep=sleep, clock=clock)
        self.assertFalse(attention_log.exists())
        self.assertNotIn("attention", json.loads((self.event_dir / "status.json").read_text()))

    def test_claude_attention_flag_survives_later_status_writes(self):
        config = self.claude_config()
        config.update(typing_retry_seconds=5, typing_defer_seconds=60, typing_give_up_seconds=60,
                      attention_after_seconds=10)
        (self.event_dir / "config.json").write_text(json.dumps(config))
        clock, sleep, _, _ = self.fake_clock()
        reads = [0]
        transport = self.claude_transport(["unparseable"], [])

        def run(argv, **kwargs):
            if argv[:3] == ["herdr", "pane", "read"]:
                reads[0] += 1
                if reads[0] == 5:
                    return self.completed(argv, returncode=1, stderr="read failed")
            return transport(argv, **kwargs)

        writes = []
        real = listen_notify._atomic_json

        def record(path, value):
            if Path(path).name == "status.json":
                writes.append(value)
            real(path, value)

        with patch.object(listen_notify, "_atomic_json", record), \
                self.assertRaises(listen_notify.DeliveryDeferred):
            listen_notify.run_event(self.event_dir, run=run, sleep=sleep, clock=clock)
        first = next(index for index, value in enumerate(writes) if value.get("attention"))
        later = writes[first:]
        # The loop-top and read-error `delivering` writes after the alert keep the flag too.
        self.assertIn("last_error", [key for value in later for key in value])
        self.assertGreater(sum(value["state"] == "delivering" for value in later), 1)
        self.assertEqual([value.get("attention") for value in later], [True] * len(later))

    def test_claude_empty_input_sends_and_never_edits_the_box(self):
        self.claude_config()
        calls = []
        run = self.claude_transport([claude_screen(SUGGESTION_BOX)], calls)
        self.assertEqual(listen_notify.run_event(self.event_dir, run=run, sleep=self.fail), "delivered")
        self.assertEqual([c[:3] for c in calls], [["herdr", "pane", "list"], ["herdr", "pane", "read"],
                                                  ["herdr", "pane", "read"], ["herdr", "pane", "run"],
                                                  ["herdr", "pane", "list"]])
        self.assertTrue((self.event_dir / "queue-receipt.json").exists())

    def test_claude_typing_defers_without_touching_input_then_sends_once_empty(self):
        config = self.claude_config()
        config.update(typing_retry_seconds=5, typing_defer_seconds=60, max_delivery_attempts=1)
        (self.event_dir / "config.json").write_text(json.dumps(config))
        calls, waiting = [], []
        clock, advance, sleeps, _ = self.fake_clock()

        def sleep(seconds):
            advance(seconds)
            waiting.append(json.loads((self.event_dir / "status.json").read_text()))
            self.assertFalse((self.event_dir / "queue-receipt.json").exists())

        run = self.claude_transport(
            [claude_screen(TYPED_BOX), claude_screen(EMPTY_BOX, "  more"), claude_screen(EMPTY_BOX)], calls)
        self.assertEqual(listen_notify.run_event(self.event_dir, run=run, sleep=sleep, clock=clock), "delivered")
        self.assertEqual(sleeps, [5, 5])
        self.assertEqual([w["state"] for w in waiting], ["waiting-user-typing"] * 2)
        self.assertEqual(waiting[0]["input"], "typing")
        self.assertEqual([c[:3] for c in calls], [
            ["herdr", "pane", "list"], ["herdr", "pane", "read"],
            ["herdr", "pane", "list"], ["herdr", "pane", "read"],
            ["herdr", "pane", "list"], ["herdr", "pane", "read"], ["herdr", "pane", "read"],
            ["herdr", "pane", "run"], ["herdr", "pane", "list"]])
        self.assertEqual(json.loads((self.event_dir / "status.json").read_text())["state"], "delivered")
        self.assertIn("held 10s", (self.event_dir / "notification.txt").read_text())

    def test_claude_typing_past_deadline_records_deferral_and_keeps_event(self):
        config = self.claude_config()
        config.update(typing_retry_seconds=5, typing_defer_seconds=10, typing_give_up_seconds=10)
        (self.event_dir / "config.json").write_text(json.dumps(config))
        poll_before = (self.event_dir / "poll-result.json").read_text()
        for screen, reason in ((claude_screen(TYPED_BOX), "typing"), ("unparseable", "unknown")):
            with self.subTest(reason=reason):
                (self.event_dir / "status.json").unlink(missing_ok=True)
                calls = []
                clock, sleep, sleeps, _ = self.fake_clock()
                run = self.claude_transport([screen], calls)
                with self.assertRaises(listen_notify.DeliveryDeferred):
                    listen_notify.run_event(self.event_dir, run=run, sleep=sleep, clock=clock)
                self.assertEqual(sleeps, [5, 5])
                self.assertEqual(sum(c[:3] == ["herdr", "pane", "read"] for c in calls), 3)
                self.assertFalse(any(c[:3] == ["herdr", "pane", "run"] for c in calls))
                self.assertTrue(all(c[:3] in (["herdr", "pane", "list"], ["herdr", "pane", "read"])
                                    for c in calls))
                status = json.loads((self.event_dir / "status.json").read_text())
                self.assertEqual(status["state"], "deferred-user-typing")
                self.assertEqual(status["input"], reason)
                self.assertEqual(status["deferred_seconds"], 10)
                self.assertFalse(status["retrying"])
                self.assertFalse((self.event_dir / "queue-receipt.json").exists())
                self.assertEqual((self.event_dir / "poll-result.json").read_text(), poll_before)
                self.assertTrue((self.event_dir / "notification.txt").exists())
        launches = []

        class Process:
            pid = 99999999

        self.assertEqual(listen_notify.start_listener(
            self.event_dir, config, launch=lambda *a, **k: launches.append(a) or Process()), "started")
        self.assertEqual(len(launches), 1)
        calls = []
        self.assertEqual(listen_notify.run_event(
            self.event_dir, run=self.claude_transport([claude_screen(EMPTY_BOX)], calls)), "delivered")
        self.assertEqual(sum(c[:3] == ["herdr", "pane", "run"] for c in calls), 1)

    def test_claude_input_is_rechecked_immediately_before_send_and_aborts_if_it_changed(self):
        config = self.claude_config()
        config.update(typing_retry_seconds=5, max_delivery_attempts=1)
        (self.event_dir / "config.json").write_text(json.dumps(config))
        calls, seen = [], []
        clock, sleep, sleeps, _ = self.fake_clock()

        def on_read():
            status = self.event_dir / "status.json"
            seen.append(json.loads(status.read_text())["state"] if status.exists() else None)

        # Empty at the first check, a keystroke before the gate read, then empty twice.
        run = self.claude_transport([claude_screen(EMPTY_BOX), claude_screen("❯\xa0h"),
                                     claude_screen(EMPTY_BOX)], calls, on_read=on_read)
        self.assertEqual(listen_notify.run_event(self.event_dir, run=run, sleep=sleep, clock=clock), "delivered")
        self.assertEqual(sleeps, [5])
        self.assertEqual([c[:3] for c in calls], [
            ["herdr", "pane", "list"], ["herdr", "pane", "read"], ["herdr", "pane", "read"],
            ["herdr", "pane", "list"], ["herdr", "pane", "read"], ["herdr", "pane", "read"],
            ["herdr", "pane", "run"], ["herdr", "pane", "list"]])
        # The gate read is the last thing before the send: uncertainty is already on disk.
        self.assertEqual(seen, ["delivering", "delivery-uncertain", "delivering", "delivery-uncertain"])

    def test_claude_failed_gate_read_is_a_preflight_failure_without_send(self):
        config = self.claude_config()
        config["max_delivery_attempts"] = 2
        (self.event_dir / "config.json").write_text(json.dumps(config))
        calls, sleeps = [], []
        reads = 0

        def run(argv, **_):
            nonlocal reads
            calls.append(argv)
            if argv == ["herdr", "pane", "list"]:
                return self.completed(argv, stdout=json.dumps(self.pane_list()))
            if argv[:3] == ["herdr", "pane", "read"]:
                reads += 1
                if reads % 2 == 0:
                    return self.completed(argv, returncode=1, stderr="gate read failed")
                return self.completed(argv, stdout=claude_screen(EMPTY_BOX))
            self.fail("must not send after a failed gate read")

        with self.assertRaisesRegex(listen_notify.DeliveryError, "gate read failed"):
            listen_notify.run_event(self.event_dir, run=run, sleep=sleeps.append)
        self.assertEqual(sleeps, [1])
        self.assertEqual(json.loads((self.event_dir / "status.json").read_text())["state"], "delivery-failed")
        self.assertFalse((self.event_dir / "queue-receipt.json").exists())

    def test_claude_hold_uses_a_monotonic_deadline_including_herdr_call_time(self):
        config = self.claude_config()
        config.update(typing_retry_seconds=5, typing_defer_seconds=20, typing_give_up_seconds=20)
        (self.event_dir / "config.json").write_text(json.dumps(config))
        clock, sleep, sleeps, timed = self.fake_clock(call_seconds=7)
        run = timed(self.claude_transport([claude_screen(TYPED_BOX)], []))
        with self.assertRaises(listen_notify.DeliveryDeferred):
            listen_notify.run_event(self.event_dir, run=run, sleep=sleep, clock=clock)
        # Held from the first non-empty read (t=14): 5 s sleep, then the last sleep is capped to
        # the 1 s left, and the deferral reports the real 34 s that passed, not the 6 s slept.
        self.assertEqual(sleeps, [5, 1])
        status = json.loads((self.event_dir / "status.json").read_text())
        self.assertEqual((status["state"], status["deferred_seconds"]), ("deferred-user-typing", 34))

    def test_claude_deferral_keeps_retrying_slowly_and_is_visible_until_give_up(self):
        config = self.claude_config()
        config.update(typing_retry_seconds=5, typing_defer_seconds=10, typing_give_up_seconds=130)
        (self.event_dir / "config.json").write_text(json.dumps(config))
        clock, advance, sleeps, _ = self.fake_clock()
        states = []

        def sleep(seconds):
            states.append(json.loads((self.event_dir / "status.json").read_text()))
            advance(seconds)

        run = self.claude_transport([claude_screen(TYPED_BOX)], [])
        with self.assertRaisesRegex(listen_notify.DeliveryDeferred, "130s"):
            listen_notify.run_event(self.event_dir, run=run, sleep=sleep, clock=clock)
        self.assertEqual(sleeps, [5, 5, 60, 60])
        self.assertEqual([s["state"] for s in states], ["waiting-user-typing"] * 2 + ["deferred-user-typing"] * 2)
        self.assertTrue(all(s["retrying"] for s in states))
        final = json.loads((self.event_dir / "status.json").read_text())
        self.assertEqual((final["state"], final["retrying"], final["deferred_seconds"]),
                         ("deferred-user-typing", False, 130))
        self.assertFalse((self.event_dir / "queue-receipt.json").exists())

        # The user clears the box during the slow phase: the event is delivered and says it was held.
        (self.event_dir / "status.json").unlink()
        clock, sleep, sleeps, _ = self.fake_clock()
        calls = []
        run = self.claude_transport([claude_screen(TYPED_BOX)] * 3 + [claude_screen(EMPTY_BOX)], calls)
        self.assertEqual(listen_notify.run_event(self.event_dir, run=run, sleep=sleep, clock=clock), "delivered")
        self.assertEqual(sleeps, [5, 5, 60])
        self.assertEqual(sum(c[:3] == ["herdr", "pane", "run"] for c in calls), 1)
        self.assertIn("held 70s", (self.event_dir / "notification.txt").read_text())

    def test_claude_event_lock_blocks_a_concurrent_run_during_the_hold(self):
        config = self.claude_config()
        config.update(typing_retry_seconds=5)
        (self.event_dir / "config.json").write_text(json.dumps(config))
        holding, release = threading.Event(), threading.Event()
        calls, results = [], []
        clock, advance, _, _ = self.fake_clock()

        def sleep(seconds):
            holding.set()
            self.assertTrue(release.wait(timeout=5))
            advance(seconds)

        run = self.claude_transport([claude_screen(TYPED_BOX), claude_screen(EMPTY_BOX)], calls)
        first = threading.Thread(target=lambda: results.append(
            listen_notify.run_event(self.event_dir, run=run, sleep=sleep, clock=clock)))
        second = threading.Thread(target=lambda: results.append(
            listen_notify.run_event(self.event_dir, run=run, sleep=self.fail, clock=clock)))
        first.start()
        self.assertTrue(holding.wait(timeout=5))
        before = len(calls)
        second.start()
        second.join(timeout=0.3)
        self.assertTrue(second.is_alive(), "a concurrent run must wait for the held event lock")
        self.assertEqual(len(calls), before)
        release.set()
        first.join(timeout=5)
        second.join(timeout=5)
        self.assertCountEqual(results, ["delivered", "already-delivered"])
        self.assertEqual(sum(c[:3] == ["herdr", "pane", "run"] for c in calls), 1)

    def test_claude_pane_identity_change_mid_hold_uses_preflight_attempts_and_never_sends(self):
        config = self.claude_config()
        config.update(typing_retry_seconds=5, max_delivery_attempts=2)
        (self.event_dir / "config.json").write_text(json.dumps(config))
        calls = []
        clock, sleep, sleeps, _ = self.fake_clock()

        def run(argv, **_):
            calls.append(argv)
            if argv == ["herdr", "pane", "list"]:
                terminal = "term_123abc" if len(calls) == 1 else "term_replacement"
                return self.completed(argv, stdout=json.dumps(self.pane_list(terminal=terminal)))
            if argv[:3] == ["herdr", "pane", "read"]:
                return self.completed(argv, stdout=claude_screen(TYPED_BOX))
            self.fail("must not send to a changed pane")

        with self.assertRaisesRegex(listen_notify.DeliveryError, "identity changed"):
            listen_notify.run_event(self.event_dir, run=run, sleep=sleep, clock=clock)
        self.assertEqual(sleeps, [5, 1])
        self.assertEqual([c[:3] for c in calls], [["herdr", "pane", "list"], ["herdr", "pane", "read"],
                                                  ["herdr", "pane", "list"], ["herdr", "pane", "list"]])
        self.assertEqual(json.loads((self.event_dir / "status.json").read_text())["state"], "delivery-failed")

    def test_status_command_surfaces_parked_and_stuck_events(self):
        root = self.root / "listeners"

        def event(name, status, pid=None):
            directory = root / name
            directory.mkdir(parents=True)
            (directory / "config.json").write_text(json.dumps({"event": name}))
            (directory / "status.json").write_text(json.dumps(dict(status, event=name)))
            if pid is not None:
                (directory / "pid").write_text(str(pid) + "\n")

        event("a-delivered", {"state": "delivered"}, pid=99999999)
        event("b-waiting", {"state": "waiting-user-typing", "input": "typing", "deferred_seconds": 12.5},
              pid=os.getpid())
        event("c-deferred", {"state": "deferred-user-typing", "input": "unknown", "deferred_seconds": 900,
                             "retrying": False}, pid=99999999)
        event("d-polling-dead", {"state": "polling"}, pid=99999999)
        event("e-uncertain", {"state": "delivery-uncertain", "reason": "x"}, pid=99999999)
        event("f-dialog-flagged", {"state": "waiting-user-typing", "input": "dialog", "deferred_seconds": 700,
                                   "attention": True}, pid=os.getpid())
        (root / "not-an-event").mkdir()
        output = []
        with patch("builtins.print", lambda *a, **_k: output.append(" ".join(map(str, a)))):
            code = listen_notify.main(["status", "--state-root", str(root)])
        self.assertEqual(code, 3)
        lines = {line.split()[1]: line for line in output}
        self.assertEqual(sorted(lines), ["b-waiting", "c-deferred", "d-polling-dead", "e-uncertain",
                                         "f-dialog-flagged"])
        self.assertTrue(lines["b-waiting"].startswith("active b-waiting state=waiting-user-typing worker=running"))
        self.assertIn("input=typing", lines["b-waiting"])
        self.assertTrue(lines["c-deferred"].startswith("attention c-deferred state=deferred-user-typing"))
        self.assertIn("deferred_seconds=900", lines["c-deferred"])
        self.assertTrue(lines["d-polling-dead"].startswith("attention d-polling-dead state=polling worker=stopped"))
        self.assertTrue(lines["e-uncertain"].startswith("attention e-uncertain"))
        self.assertTrue(lines["f-dialog-flagged"].startswith(
            "attention f-dialog-flagged state=waiting-user-typing worker=running input=dialog"))
        output.clear()
        quiet = self.root / "quiet"
        with patch("builtins.print", lambda *a, **_k: output.append(" ".join(map(str, a)))):
            self.assertEqual(listen_notify.main(["status", "--state-root", str(quiet)]), 0)
        self.assertEqual(output, [])

    def test_status_survives_non_object_status_and_foreign_pid(self):
        root = self.root / "listeners"
        for name, raw in (("a-list", "[]"), ("b-scalar", "5"), ("c-foreign", '{"state": "polling"}'),
                          ("d-ok", '{"state": "polling"}')):
            directory = root / name
            directory.mkdir(parents=True)
            (directory / "config.json").write_text(json.dumps({"event": name}))
            (directory / "status.json").write_text(raw)
            (directory / "pid").write_text(("424242" if name == "c-foreign" else str(os.getpid())) + "\n")
        real_kill = os.kill

        def kill(pid, signal):
            if pid == 424242:
                raise PermissionError(1, "Operation not permitted")
            return real_kill(pid, signal)

        output = []
        with patch.object(listen_notify.os, "kill", kill), \
                patch("builtins.print", lambda *a, **_k: output.append(" ".join(map(str, a)))):
            code = listen_notify.main(["status", "--state-root", str(root)])
            # A stale pid reused by another user's process is not our worker: start launches a new one.
            (self.event_dir / "pid").write_text("424242\n")
            self.assertEqual(listen_notify.start_listener(
                self.event_dir, self.config, launch=lambda *a, **k: type("P", (), {"pid": 4242})()), "started")
        self.assertEqual(code, 3)
        lines = {line.split()[1]: line for line in output}
        self.assertEqual(sorted(lines), ["a-list", "b-scalar", "c-foreign", "d-ok"])
        self.assertTrue(lines["a-list"].startswith("attention a-list state=invalid worker=running"))
        self.assertTrue(lines["b-scalar"].startswith("attention b-scalar state=invalid worker=running"))
        self.assertTrue(lines["c-foreign"].startswith("attention c-foreign state=polling worker=foreign"))
        self.assertTrue(lines["d-ok"].startswith("active d-ok state=polling worker=running"))

    def test_claude_unreadable_input_is_a_preflight_failure_before_send(self):
        config = self.claude_config()
        config["max_delivery_attempts"] = 2
        (self.event_dir / "config.json").write_text(json.dumps(config))
        calls, sleeps = [], []

        def run(argv, **_):
            calls.append(argv)
            if argv == ["herdr", "pane", "list"]:
                return self.completed(argv, stdout=json.dumps(self.pane_list()))
            if argv[:3] == ["herdr", "pane", "read"]:
                return self.completed(argv, returncode=1, stderr="pane read failed")
            self.fail("must not send after a failed read")

        with self.assertRaisesRegex(listen_notify.DeliveryError, "pane read failed"):
            listen_notify.run_event(self.event_dir, run=run, sleep=sleeps.append)
        self.assertEqual(sleeps, [1])
        self.assertEqual(json.loads((self.event_dir / "status.json").read_text())["state"], "delivery-failed")

    def test_typing_hold_settings_are_validated_and_set_from_cli(self):
        config = self.claude_config()
        for field, value in (("typing_retry_seconds", 0), ("typing_retry_seconds", 301),
                             ("typing_retry_seconds", "5"), ("typing_defer_seconds", -1),
                             ("typing_defer_seconds", 86401), ("typing_defer_seconds", float("nan")),
                             ("typing_give_up_seconds", True), ("typing_give_up_seconds", 86401),
                             ("typing_give_up_seconds", float("inf")), ("typing_give_up_seconds", 899),
                             ("attention_after_seconds", 0), ("attention_after_seconds", 86401),
                             ("attention_after_seconds", "600"), ("attention_after_seconds", False),
                             ("attention_after_seconds", float("nan")), ("attention_after_seconds", float("inf"))):
            with self.subTest(field=field, value=value), self.assertRaisesRegex(ValueError, field):
                listen_notify._validate_config(dict(config, **{field: value}))
        listen_notify._validate_config(dict(config, typing_retry_seconds=0.5, typing_defer_seconds=0))
        listen_notify._validate_config(dict(config, typing_defer_seconds=0, typing_give_up_seconds=0))
        # Old events without a give-up bound keep a valid one even with a long hold.
        listen_notify._validate_config(dict(config, typing_defer_seconds=20000))
        args = listen_notify._build_parser().parse_args([
            "start", "--event", "typing-cli", "--task", "typing-cli", "--agent", "gpt-auditor",
            "--handoff", str(self.handoff), "--poll", "idle", "--route", "claude-pane",
            "--pane", "w1:p1", "--terminal-id", "term_123abc", "--cwd", "/tmp/picsee",
            "--typing-retry-seconds", "3", "--typing-defer-seconds", "120", "--typing-give-up-seconds", "600",
            "--attention-after-seconds", "45",
        ])
        built = listen_notify._config_from_args(args)
        self.assertEqual((built["typing_retry_seconds"], built["typing_defer_seconds"],
                          built["typing_give_up_seconds"], built["attention_after_seconds"]), (3, 120, 600, 45))
        defaults = listen_notify._config_from_args(listen_notify._build_parser().parse_args([
            "start", "--event", "typing-cli", "--task", "typing-cli", "--agent", "gpt-auditor",
            "--handoff", str(self.handoff), "--poll", "idle", "--route", "claude-pane",
            "--pane", "w1:p1", "--terminal-id", "term_123abc", "--cwd", "/tmp/picsee"]))
        self.assertEqual((defaults["typing_retry_seconds"], defaults["typing_defer_seconds"],
                          defaults["typing_give_up_seconds"], defaults["attention_after_seconds"]),
                         (5, 900, 14400, 600))

    def test_claude_cli_keeps_copied_symlink_alias_for_preflight(self):
        real_cwd = self.root / "real-picsee"
        real_cwd.mkdir()
        alias = self.root / "alias-picsee"
        alias.symlink_to(real_cwd, target_is_directory=True)
        parser = listen_notify._build_parser()
        args = parser.parse_args([
            "start", "--event", "alias-event", "--task", "alias-event",
            "--agent", "gpt-auditor", "--handoff", str(self.handoff),
            "--poll", "idle", "--route", "claude-pane", "--pane", "w1:p1",
            "--terminal-id", "term_123abc", "--cwd", str(alias),
        ])
        config = listen_notify._config_from_args(args)
        self.assertEqual(config["destination"]["cwd"], str(alias))
        calls = []

        def run(argv, **_):
            calls.append(argv)
            if argv == ["herdr", "pane", "list"]:
                return self.completed(argv, stdout=json.dumps(self.pane_list(cwd=str(alias))))
            return self.completed(argv)

        listen_notify._checked_claude_pane(config["destination"], run)
        self.assertEqual(calls, [["herdr", "pane", "list"]])

    def test_event_identity_rejects_cross_route_reuse(self):
        listen_notify.register_event(self.event_dir, self.config)
        new = dict(self.config)
        new.pop("thread")
        new["schema"] = 2
        new["destination"] = {
            "kind": "claude-pane", "pane": "w1:p1",
            "terminal_id": "term_123abc", "cwd": "/tmp/picsee",
        }
        with self.assertRaises(listen_notify.EventIdentityError):
            listen_notify.register_event(self.event_dir, new)

    def test_route_cli_builds_explicit_destinations_and_keeps_old_schema(self):
        parser = listen_notify._build_parser()
        base = ["start", "--event", "route-test", "--task", "route-test",
                "--agent", "gpt-auditor", "--handoff", str(self.handoff),
                "--poll", "idle", "--state-root", str(self.root)]
        old = listen_notify._config_from_args(parser.parse_args(base + [
            "--thread", self.config["thread"]]))
        self.assertEqual(old["schema"], 1)
        self.assertEqual(old["thread"], self.config["thread"])
        codex = listen_notify._config_from_args(parser.parse_args(base + [
            "--route", "codex-thread", "--thread", self.config["thread"]]))
        self.assertEqual(codex["schema"], 2)
        self.assertEqual(codex["destination"]["kind"], "codex-thread")
        claude = listen_notify._config_from_args(parser.parse_args(base + [
            "--route", "claude-pane", "--pane", "w1:p1", "--terminal-id",
            "term_123abc", "--cwd", "/tmp/picsee"]))
        self.assertEqual(claude["schema"], 2)
        self.assertEqual(claude["destination"]["kind"], "claude-pane")
        self.assertNotIn("thread", claude)
        for invalid in (
            base,
            base + ["--route", "claude-pane", "--pane", "w1:p1"],
            base + ["--route", "claude-pane", "--pane", "w1:p1",
                    "--terminal-id", "term_123abc", "--cwd", "/tmp/picsee",
                    "--thread", self.config["thread"]],
            base + ["--route", "codex-thread", "--thread", self.config["thread"],
                    "--pane", "w1:p1"],
        ):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                listen_notify._config_from_args(parser.parse_args(invalid))

    def test_explicit_codex_route_delivers_to_its_thread(self):
        config = dict(self.config)
        config.pop("thread")
        config["schema"] = 2
        config["destination"] = {"kind": "codex-thread", "thread": self.config["thread"]}
        (self.event_dir / "config.json").write_text(json.dumps(config))
        (self.event_dir / "poll-result.json").write_text(json.dumps({
            "outcome": "done", "exit_code": 0, "handoff_evidence": "ready",
        }))
        calls = []

        def run(argv, **_):
            calls.append(argv)
            return self.completed(argv, stdout="queued")

        self.assertEqual(listen_notify.run_event(self.event_dir, run=run), "delivered")
        self.assertEqual(calls[0][:4], ["codex", "queue", "--thread", self.config["thread"]])
        receipt = json.loads((self.event_dir / "queue-receipt.json").read_text())
        self.assertEqual(receipt["destination"], config["destination"])
        self.assertNotIn("thread", receipt)

    def test_delivery_retries_with_bounded_backoff_and_marks_only_after_success(self):
        self.handoff.write_text("DONE\n")
        os.utime(self.handoff, (1_800_000_001, 1_800_000_001))
        queue_attempts = 0
        sleeps = []

        def run(argv, **kwargs):
            nonlocal queue_attempts
            if argv[0] != "codex":
                return self.completed(argv, stdout="gpt-imple-3 idle 12:00:00\n")
            queue_attempts += 1
            self.assertFalse((self.event_dir / "queue-receipt.json").exists())
            if queue_attempts < 3:
                return self.completed(argv, returncode=1, stderr="transport offline")
            return self.completed(argv, stdout="queued on third attempt")

        result = listen_notify.run_event(self.event_dir, run=run, sleep=sleeps.append)

        self.assertEqual(result, "delivered")
        self.assertEqual(queue_attempts, 3)
        self.assertEqual(sleeps, [1, 2])
        self.assertTrue((self.event_dir / "poll-result.json").exists())
        self.assertTrue((self.event_dir / "queue-receipt.json").exists())

    def test_exhausted_delivery_preserves_poll_evidence_for_later_retry(self):
        poll_calls = 0

        def fail(argv, **kwargs):
            nonlocal poll_calls
            if argv[0] != "codex":
                poll_calls += 1
                return self.completed(argv, stdout="gpt-imple-3 question 12:00:00\n")
            return self.completed(argv, returncode=1, stderr="transport offline")

        with self.assertRaises(listen_notify.DeliveryError):
            listen_notify.run_event(self.event_dir, run=fail, sleep=lambda _: None)

        self.assertEqual(poll_calls, 1)
        self.assertTrue((self.event_dir / "poll-result.json").exists())
        self.assertFalse((self.event_dir / "queue-receipt.json").exists())
        status = json.loads((self.event_dir / "status.json").read_text())
        self.assertEqual(status["state"], "delivery-failed")

        def recover(argv, **kwargs):
            if argv[0] != "codex":
                self.fail("a delivery retry must reuse retained poll evidence")
            return self.completed(argv, stdout="queued after recovery")

        self.assertEqual(listen_notify.run_event(self.event_dir, run=recover), "delivered")
        self.assertEqual(poll_calls, 1)

    def test_concurrent_delivery_for_same_event_queues_once(self):
        self.handoff.write_text("DONE\n")
        os.utime(self.handoff, (1_800_000_001, 1_800_000_001))
        (self.event_dir / "poll-result.json").write_text(
            json.dumps(
                {
                    "outcome": "idle",
                    "exit_code": 0,
                    "output": "gpt-imple-3 idle",
                    "handoff_evidence": "ready",
                }
            )
        )
        queue_calls = 0
        queue_started = threading.Event()
        allow_queue_to_finish = threading.Event()

        def run(argv, **kwargs):
            nonlocal queue_calls
            queue_calls += 1
            queue_started.set()
            allow_queue_to_finish.wait(timeout=2)
            return self.completed(argv, stdout="queued once")

        results = []
        threads = [
            threading.Thread(target=lambda: results.append(listen_notify.run_event(self.event_dir, run=run)))
            for _ in range(2)
        ]
        threads[0].start()
        self.assertTrue(queue_started.wait(timeout=2))
        threads[1].start()
        allow_queue_to_finish.set()
        for thread in threads:
            thread.join(timeout=2)

        self.assertEqual(queue_calls, 1)
        self.assertCountEqual(results, ["delivered", "already-delivered"])

    def test_reusing_event_with_different_identity_is_rejected(self):
        listen_notify.register_event(self.event_dir, self.config)
        changed = dict(self.config, thread="aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")

        with self.assertRaisesRegex(listen_notify.EventIdentityError, "different identity"):
            listen_notify.register_event(self.event_dir, changed)

    def test_poll_failure_timeout_block_and_missing_or_stale_handoff_are_not_certified(self):
        cases = [
            (1, "poll crashed", "poll-error", "missing"),
            (0, "gpt-imple-3 timeout status=working", "timeout", "missing"),
            (0, "gpt-imple-3 blocked 12:00:00", "blocked", "missing"),
            (0, "gpt-imple-3 question 12:00:00", "question", "missing"),
            (0, "gpt-imple-3 idle 12:00:00", "idle", "missing"),
        ]
        for index, (returncode, output, outcome, evidence) in enumerate(cases):
            with self.subTest(outcome=outcome):
                event_dir = self.root / f"case-{index}"
                event_dir.mkdir()
                (event_dir / "config.json").write_text(json.dumps(self.config))
                messages = []

                def run(argv, **kwargs):
                    if argv[0] != "codex":
                        return self.completed(argv, returncode=returncode, stdout=output)
                    messages.append(argv[-1])
                    return self.completed(argv, stdout="queued")

                self.assertEqual(listen_notify.run_event(event_dir, run=run), "delivered")
                poll_result = json.loads((event_dir / "poll-result.json").read_text())
                self.assertEqual(poll_result["outcome"], outcome)
                self.assertEqual(poll_result["handoff_evidence"], evidence)
                self.assertIn("needs inspection", messages[0].lower())
                self.assertNotIn("accepted", messages[0].lower())

        self.handoff.write_text("old report")
        os.utime(self.handoff, (1_799_999_999, 1_799_999_999))
        stale_dir = self.root / "stale"
        stale_dir.mkdir()
        (stale_dir / "config.json").write_text(json.dumps(self.config))

        def stale_run(argv, **kwargs):
            if argv[0] != "codex":
                return self.completed(argv, stdout="gpt-imple-3 idle 12:00:00")
            return self.completed(argv, stdout="queued")

        listen_notify.run_event(stale_dir, run=stale_run)
        result = json.loads((stale_dir / "poll-result.json").read_text())
        self.assertEqual(result["handoff_evidence"], "stale")

    def test_report_mode_requires_round_marker_and_binds_it_to_event_identity(self):
        parser = listen_notify._build_parser()
        args = parser.parse_args([
            "start", "--event", "new-round", "--task", "issue90-confirm3",
            "--thread", self.config["thread"], "--agent", "gpt-auditor",
            "--handoff", str(self.handoff), "--poll", "report",
            "--handoff-marker", "issue90-confirm3", "--interval", "2",
            "--max-minutes", "10",
        ])
        config = listen_notify._config_from_args(args)
        self.assertEqual(Path(config["poll"][0]).name, "poll-report.py")
        self.assertIn("issue90-confirm3", config["poll"])
        self.assertEqual(config["handoff_marker"], "issue90-confirm3")
        report_event_dir = self.root / "report-repeat"
        listen_notify.register_event(report_event_dir, config)
        self.assertEqual(
            listen_notify.register_event(report_event_dir, listen_notify._config_from_args(args)),
            "already-registered",
        )
        with self.assertRaisesRegex(ValueError, "handoff_marker"):
            listen_notify._validate_config(dict(config, handoff_marker=None))
        with self.assertRaisesRegex(ValueError, "handoff_marker"):
            listen_notify._validate_config(dict(config, handoff_marker="DONE"))

    def test_report_mode_rejects_blank_identity_at_cli_and_persisted_boundaries(self):
        parser = listen_notify._build_parser()
        for task, marker in (("", ""), ("   ", "   "), ("issue90-r1", "  ")):
            with self.subTest(task=task, marker=marker):
                args = parser.parse_args([
                    "start", "--event", "blank-round", "--task", task,
                    "--thread", self.config["thread"], "--agent", "gpt-auditor",
                    "--handoff", str(self.handoff), "--poll", "report",
                    "--handoff-marker", marker,
                ])
                with self.assertRaisesRegex(ValueError, "non-empty"):
                    listen_notify._config_from_args(args)
                persisted = dict(self.config, task=task, handoff_marker=marker,
                                 poll=[str(REPORT_SCRIPT), "gpt-auditor", str(self.handoff)])
                (self.event_dir / "config.json").write_text(json.dumps(persisted))
                with self.assertRaisesRegex(ValueError, "non-empty"):
                    listen_notify.run_event(self.event_dir, run=lambda *_args, **_kwargs: self.fail("must not poll"))

    def test_idle_with_old_matching_report_waits_for_fresh_report(self):
        self.handoff.write_text("Report-Task: issue90-r1\n")
        os.utime(self.handoff, (1_799_999_999, 1_799_999_999))
        observations = []

        def status(_agent):
            observations.append("idle")
            return "idle"

        def advance(_seconds):
            if len(observations) == 2:
                os.utime(self.handoff, (1_800_000_001, 1_800_000_001))

        result = poll_report.watch(
            "gpt-auditor", self.handoff, 1_800_000_000, "issue90-r1",
            interval=1, max_minutes=1, idle_grace_seconds=5,
            get_status=status, sleep=advance,
            monotonic=iter([0, 0, 1, 2]).__next__,
        )
        self.assertEqual(result, "done")
        self.assertEqual(len(observations), 3, "old report must not stop polling")

    def test_done_with_fresh_wrong_identity_waits_for_correct_report(self):
        self.handoff.write_text("Report-Task: issue90-r10\n")
        os.utime(self.handoff, (1_800_000_001, 1_800_000_001))
        observations = []

        def status(_agent):
            observations.append("done")
            return "done"

        def advance(_seconds):
            if len(observations) == 2:
                self.handoff.write_text("Report-Task: issue90-r1\n")
                os.utime(self.handoff, (1_800_000_002, 1_800_000_002))

        result = poll_report.watch(
            "gpt-auditor", self.handoff, 1_800_000_000, "issue90-r1",
            interval=1, max_minutes=1, idle_grace_seconds=5,
            get_status=status, sleep=advance,
            monotonic=iter([0, 0, 1, 2]).__next__,
        )
        self.assertEqual(result, "done")
        self.assertEqual(len(observations), 3, "wrong task must not stop polling")

    def test_report_identity_field_must_be_unique_and_poll_path_must_match_config(self):
        self.handoff.write_text("Report-Task: issue90-r1\nReport-Task: issue90-r1\n")
        os.utime(self.handoff, (1_800_000_001, 1_800_000_001))
        self.assertFalse(poll_report._fresh_report(self.handoff, 1_800_000_000, "issue90-r1"))
        config = dict(self.config, task="issue90-r1", handoff_marker="issue90-r1",
                      poll=[str(REPORT_SCRIPT), "gpt-auditor", str(self.root / "other.md"),
                            str(self.event_dir / "config.json"), "issue90-r1", "1", "1", "1"])
        with self.assertRaisesRegex(ValueError, "report path"):
            listen_notify._validate_config(config)

    def test_report_poll_finds_fresh_report_at_idle_despite_scrolled_viewport(self):
        self.handoff.write_text("Report-Task: issue90-confirm3\nDONE\n")
        os.utime(self.handoff, (1_800_000_001, 1_800_000_001))
        statuses = iter(["working", "idle"])
        screens = ["Back to bottom; older activity", "Back to bottom; older activity"]
        result = poll_report.watch(
            "gpt-auditor", self.handoff, 1_800_000_000, "issue90-confirm3",
            interval=2, max_minutes=10, idle_grace_seconds=4,
            get_status=lambda _: next(statuses), sleep=lambda _: screens.pop(),
            monotonic=iter([0, 0, 2]).__next__,
        )
        self.assertEqual(result, "done")

    def test_old_report_does_not_complete_new_working_task(self):
        self.handoff.write_text("# issue90-old-round\nDONE\n")
        os.utime(self.handoff, (1_799_999_999, 1_799_999_999))
        times = iter([0, 0, 2, 4, 6])
        result = poll_report.watch(
            "gpt-auditor", self.handoff, 1_800_000_000, "issue90-new-round",
            interval=2, max_minutes=0.1, idle_grace_seconds=4,
            get_status=lambda _: "working", sleep=lambda _: None,
            monotonic=times.__next__,
        )
        self.assertEqual(result, "timeout")

    def test_idle_without_report_surfaces_missing_handoff_after_grace(self):
        times = iter([0, 0, 2, 4])
        result = poll_report.watch(
            "gpt-auditor", self.handoff, 1_800_000_000, "issue90-new-round",
            interval=2, max_minutes=10, idle_grace_seconds=4,
            get_status=lambda _: "idle", sleep=lambda _: None,
            monotonic=times.__next__,
        )
        self.assertEqual(result, "missing-handoff")
        self.assertEqual(listen_notify._classify_poll(0, "gpt-auditor missing-handoff"), "missing-handoff")

    def test_blocked_without_report_surfaces_immediately(self):
        result = poll_report.watch(
            "gpt-auditor", self.handoff, 1_800_000_000, "issue90-new-round",
            interval=2, max_minutes=10, idle_grace_seconds=4,
            get_status=lambda _: "blocked", sleep=lambda _: self.fail("blocked must not sleep"),
            monotonic=iter([0, 0]).__next__,
        )
        self.assertEqual(result, "blocked")

    def test_report_mode_worker_uses_fake_herdr_and_queue_without_viewport(self):
        fake_bin = self.root / "fake-report-bin"
        fake_bin.mkdir()
        captured = self.root / "report-message.txt"
        herdr = fake_bin / "herdr"
        herdr.write_text("#!/bin/sh\nprintf '%s\\n' '{\"id\":\"cli:agent:get\",\"result\":{\"type\":\"agent_info\",\"agent\":{\"name\":\"gpt-auditor\",\"agent_status\":\"idle\"}}}'\n")
        herdr.chmod(0o755)
        codex = fake_bin / "codex"
        codex.write_text(
            "#!/usr/bin/env python3\n"
            "import os, sys\n"
            "open(os.environ['CAPTURED_MESSAGE'], 'w').write(sys.argv[-1])\n"
            "print('scratch queued')\n"
        )
        codex.chmod(0o755)
        args = listen_notify._build_parser().parse_args([
            "start", "--event", self.event_dir.name, "--task", "issue90-report-test",
            "--thread", self.config["thread"], "--agent", "gpt-auditor",
            "--handoff", str(self.handoff), "--handoff-marker", "issue90-report-test",
            "--poll", "report", "--interval", "1", "--max-minutes", "1",
            "--state-root", str(self.event_dir.parent),
        ])
        config = listen_notify._config_from_args(args)
        self.handoff.write_text("Report-Task: issue90-report-test\nCompleted\n")
        (self.event_dir / "config.json").write_text(json.dumps(config))
        environment = dict(os.environ, CAPTURED_MESSAGE=str(captured))
        environment["PATH"] = str(fake_bin) + os.pathsep + environment["PATH"]
        completed = subprocess.run(
            [sys.executable, str(SCRIPT), "run", "--event-dir", str(self.event_dir)],
            capture_output=True, text=True, env=environment, timeout=5,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        result = json.loads((self.event_dir / "poll-result.json").read_text())
        self.assertEqual(result["outcome"], "done")
        self.assertEqual(result["handoff_evidence"], "ready")
        self.assertIn("issue90-report-test", captured.read_text())

    def test_real_report_worker_rejects_prefix_collision_and_blank_config(self):
        fake_bin = self.root / "fake-identity-bin"
        fake_bin.mkdir()
        herdr = fake_bin / "herdr"
        herdr.write_text("#!/bin/sh\nprintf '%s\\n' '{\"id\":\"cli:agent:get\",\"result\":{\"type\":\"agent_info\",\"agent\":{\"name\":\"gpt-auditor\",\"agent_status\":\"idle\"}}}'\n")
        herdr.chmod(0o755)
        codex = fake_bin / "codex"
        codex.write_text("#!/bin/sh\nprintf 'scratch queued\\n'\n")
        codex.chmod(0o755)
        environment = dict(os.environ)
        environment["PATH"] = str(fake_bin) + os.pathsep + environment["PATH"]
        args = listen_notify._build_parser().parse_args([
            "start", "--event", self.event_dir.name, "--task", "issue90-r1",
            "--thread", self.config["thread"], "--agent", "gpt-auditor",
            "--handoff", str(self.handoff), "--handoff-marker", "issue90-r1",
            "--poll", "report", "--interval", "1", "--max-minutes", "1",
            "--idle-grace-seconds", "1", "--state-root", str(self.event_dir.parent),
        ])
        config = listen_notify._config_from_args(args)
        self.handoff.write_text("Report-Task: issue90-r10\n")
        os.utime(self.handoff, (config["created_at"] + 1, config["created_at"] + 1))
        (self.event_dir / "config.json").write_text(json.dumps(config))
        completed = subprocess.run(
            [sys.executable, str(SCRIPT), "run", "--event-dir", str(self.event_dir)],
            capture_output=True, text=True, env=environment, timeout=5,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        result = json.loads((self.event_dir / "poll-result.json").read_text())
        self.assertEqual(result["outcome"], "missing-handoff")
        self.assertEqual(result["handoff_evidence"], "stale")
        self.assertTrue((self.event_dir / "queue-receipt.json").exists())

        blank_dir = self.root / "blank-worker"
        blank_dir.mkdir()
        (blank_dir / "config.json").write_text(json.dumps(dict(config, task="", handoff_marker="")))
        blank = subprocess.run(
            [sys.executable, str(SCRIPT), "run", "--event-dir", str(blank_dir)],
            capture_output=True, text=True, env=environment, timeout=5,
        )
        self.assertNotEqual(blank.returncode, 0)
        self.assertIn("non-empty", blank.stderr)
        self.assertFalse((blank_dir / "queue-receipt.json").exists())

    def test_detached_start_uses_argv_writes_pid_and_does_not_shell_interpolate(self):
        launches = []

        class Process:
            pid = 4242

        def launch(argv, **kwargs):
            launches.append((argv, kwargs))
            return Process()

        result = listen_notify.start_listener(self.event_dir, self.config, launch=launch)

        self.assertEqual(result, "started")
        self.assertEqual((self.event_dir / "pid").read_text(), "4242\n")
        argv, kwargs = launches[0]
        self.assertIsInstance(argv, list)
        self.assertEqual(argv[-2:], ["--event-dir", str(self.event_dir)])
        self.assertTrue(kwargs["start_new_session"])
        self.assertIs(kwargs["stdin"], subprocess.DEVNULL)
        self.assertNotIn("shell", kwargs)

    def test_cli_run_uses_a_scratch_transport_and_never_queues_a_real_thread(self):
        fake_bin = self.root / "fake-bin"
        fake_bin.mkdir()
        captured = self.root / "captured-argv.json"
        fake_codex = fake_bin / "codex"
        fake_codex.write_text(
            "#!/usr/bin/env python3\n"
            "import json, os, sys\n"
            "open(os.environ['CAPTURED_ARGV'], 'w').write(json.dumps(sys.argv[1:]))\n"
            "print('scratch queue receipt')\n"
        )
        fake_codex.chmod(0o755)
        self.handoff.write_text("DONE\n")
        os.utime(self.handoff, (1_800_000_001, 1_800_000_001))
        self.config["poll"] = [
            sys.executable,
            "-c",
            "print('gpt-imple-3 idle 12:00:00')",
        ]
        (self.event_dir / "config.json").write_text(json.dumps(self.config))
        environment = dict(os.environ)
        environment["PATH"] = str(fake_bin) + os.pathsep + environment["PATH"]
        environment["CAPTURED_ARGV"] = str(captured)

        completed = subprocess.run(
            [sys.executable, str(SCRIPT), "run", "--event-dir", str(self.event_dir)],
            capture_output=True,
            text=True,
            env=environment,
        )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(completed.stdout.strip(), "delivered")
        argv = json.loads(captured.read_text())
        self.assertEqual(argv[0:3], ["queue", "--thread", self.config["thread"]])
        self.assertEqual(argv[3], "--message")
        self.assertTrue((self.event_dir / "queue-receipt.json").exists())

    def test_real_hung_poller_and_resistant_child_time_out_notify_and_exit(self):
        fake_bin = self.root / "fake-bin"
        fake_bin.mkdir()
        captured = self.root / "captured-argv.json"
        codex = fake_bin / "codex"
        codex.write_text(
            "#!/usr/bin/env python3\n"
            "import json, os, sys\n"
            "open(os.environ['CAPTURED_ARGV'], 'w').write(json.dumps(sys.argv[1:]))\n"
            "print('scratch queue receipt')\n"
        )
        codex.chmod(0o755)
        child_pid_path = self.root / "child.pid"
        hung_poll = self.root / "hung-poll.py"
        hung_poll.write_text(
            "import os, signal, subprocess, sys, time\n"
            "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
            "child = subprocess.Popen([sys.executable, '-c', "
            "'import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)'])\n"
            "open(sys.argv[1], 'w').write(str(child.pid))\n"
            "time.sleep(60)\n"
        )
        self.config["poll"] = [sys.executable, str(hung_poll), str(child_pid_path)]
        self.config["poll_deadline_seconds"] = 0.25
        self.handoff.write_text("DONE\n")
        os.utime(self.handoff, (1_800_000_001, 1_800_000_001))
        (self.event_dir / "config.json").write_text(json.dumps(self.config))
        environment = dict(os.environ)
        environment["PATH"] = str(fake_bin) + os.pathsep + environment["PATH"]
        environment["CAPTURED_ARGV"] = str(captured)
        worker = subprocess.Popen(
            [sys.executable, str(SCRIPT), "run", "--event-dir", str(self.event_dir)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=environment,
            start_new_session=True,
        )
        bystander = subprocess.Popen(
            [sys.executable, "-c", "import time; time.sleep(5)"], start_new_session=True
        )
        try:
            try:
                stdout, stderr = worker.communicate(timeout=3)
            except subprocess.TimeoutExpired:
                self.fail("listener exceeded its short poll deadline")
            self.assertEqual(worker.returncode, 0, stderr)
            self.assertEqual(stdout.strip(), "delivered")
            result = json.loads((self.event_dir / "poll-result.json").read_text())
            self.assertEqual(result["outcome"], "timeout")
            self.assertEqual(result["exit_code"], None)
            self.assertEqual(result["handoff_evidence"], "ready")
            argv = json.loads(captured.read_text())
            self.assertIn("needs inspection", argv[-1].lower())
            self.assertIn("timeout", argv[-1].lower())
            self.assertIsNone(bystander.poll(), "cleanup signalled an unrelated process group")
            child_pid = int(child_pid_path.read_text())
            for _ in range(20):
                try:
                    os.kill(child_pid, 0)
                except ProcessLookupError:
                    break
                time.sleep(0.05)
            else:
                self.fail("hung poller child survived cleanup")
        finally:
            if worker.poll() is None:
                os.killpg(worker.pid, signal.SIGKILL)
                worker.communicate(timeout=2)
            if bystander.poll() is None:
                bystander.kill()
            bystander.wait(timeout=2)

    def test_exited_poller_reaps_inherited_output_child_before_delivery(self):
        fake_bin = self.root / "fake-bin"
        fake_bin.mkdir()
        captured = self.root / "captured-argv.json"
        codex = fake_bin / "codex"
        codex.write_text(
            "#!/usr/bin/env python3\n"
            "import json, os, sys\n"
            "open(os.environ['CAPTURED_ARGV'], 'w').write(json.dumps(sys.argv[1:]))\n"
            "print('scratch queue receipt')\n"
        )
        codex.chmod(0o755)
        child_pid_path = self.root / "child.pid"
        poller = self.root / "exiting-poll.py"
        poller.write_text(
            "import subprocess, sys\n"
            "child = subprocess.Popen([sys.executable, '-c', "
            "'import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)'])\n"
            "open(sys.argv[1], 'w').write(str(child.pid))\n"
            "print('gpt-imple-3 idle 12:00:00', flush=True)\n"
        )
        self.config["poll"] = [sys.executable, str(poller), str(child_pid_path)]
        self.config["poll_deadline_seconds"] = 0.5
        self.handoff.write_text("DONE\n")
        os.utime(self.handoff, (1_800_000_001, 1_800_000_001))
        (self.event_dir / "config.json").write_text(json.dumps(self.config))
        environment = dict(os.environ)
        environment["PATH"] = str(fake_bin) + os.pathsep + environment["PATH"]
        environment["CAPTURED_ARGV"] = str(captured)
        worker = subprocess.Popen(
            [sys.executable, str(SCRIPT), "run", "--event-dir", str(self.event_dir)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=environment,
            start_new_session=True,
        )
        bystander = subprocess.Popen(
            [sys.executable, "-c", "import time; time.sleep(5)"], start_new_session=True
        )
        try:
            stdout, stderr = worker.communicate(timeout=3)
            self.assertEqual(worker.returncode, 0, stderr)
            self.assertEqual(stdout.strip(), "delivered")
            result = json.loads((self.event_dir / "poll-result.json").read_text())
            self.assertEqual(result["outcome"], "idle")
            self.assertEqual(result["handoff_evidence"], "ready")
            self.assertIsNone(bystander.poll())
            argv = json.loads(captured.read_text())
            self.assertIn("idle", argv[-1].lower())
            child_pid = int(child_pid_path.read_text())
            for _ in range(20):
                try:
                    os.kill(child_pid, 0)
                except ProcessLookupError:
                    break
                time.sleep(0.05)
            else:
                self.fail("exited poller left its inherited-output child alive")
        finally:
            if child_pid_path.exists():
                try:
                    os.kill(int(child_pid_path.read_text()), signal.SIGKILL)
                except ProcessLookupError:
                    pass
            if worker.poll() is None:
                os.killpg(worker.pid, signal.SIGKILL)
                worker.communicate(timeout=2)
            if bystander.poll() is None:
                bystander.kill()
            bystander.wait(timeout=2)


if __name__ == "__main__":
    unittest.main()
