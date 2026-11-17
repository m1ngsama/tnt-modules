import importlib.util
from pathlib import Path
import tempfile
import unittest

PATH = Path(__file__).resolve().parents[1] / "modules/guard-module/guard-module.py"
SPEC = importlib.util.spec_from_file_location("guard_module", PATH)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class GuardTests(unittest.TestCase):
    def event(self, **values):
        return dict(type="moderation.check", id="test", timestamp=1000, event="message",
                    ip="203.0.113.1", session="s-1", nickname="?", scope="public",
                    accepted=0, rejected=0, elapsed_ms=100, language="en", **values)

    def test_nickname_does_not_change_normal_behavior(self):
        guard = MODULE.Guard()
        for name in ("?", "bot", "scanner", "匿名"):
            event = self.event(plain_text="hello " + name)
            event["nickname"] = name
            self.assertEqual(guard.check(event)["action"], "allow")

    def test_blank_unicode_and_multiline_text(self):
        guard = MODULE.Guard()
        for text in ("\n", "　 \t", "\u200b\u2060"):
            self.assertEqual(guard.check(self.event(plain_text=text))["reason"], "blank_message")
        self.assertEqual(guard.check(self.event(plain_text="第一行\n第二行 👋"))["action"], "allow")

    def test_duplicates_and_reconnection_share_source_state(self):
        guard = MODULE.Guard()
        for i in range(4):
            event = self.event(plain_text="same")
            event.update(session=str(i), nickname=str(i))
            self.assertEqual(guard.check(event)["action"], "allow")
        self.assertEqual(guard.check(self.event(plain_text="same"))["reason"], "duplicate_message")

    def test_burst_and_sustained_floods(self):
        guard = MODULE.Guard()
        results = [guard.check(self.event(plain_text=str(i))) for i in range(13)]
        self.assertEqual([r["action"] for r in results[:8]], ["allow"] * 8)
        self.assertEqual(results[-1]["action"], "ban")
        guard = MODULE.Guard()
        for i in range(30):
            event = self.event(plain_text=str(i))
            event["timestamp"] += i
            self.assertEqual(guard.check(event)["action"], "allow")
        event = self.event(plain_text="over minute budget")
        event["timestamp"] += 31
        self.assertEqual(guard.check(event)["reason"], "message_rate")

    def test_private_metadata_has_a_budget_without_a_body(self):
        guard = MODULE.Guard()
        event = self.event()
        event["scope"] = "private"
        results = [guard.check(event) for _ in range(13)]
        self.assertEqual(results[0]["action"], "allow")
        self.assertEqual(results[-1]["action"], "ban")
        self.assertIsNone(guard.sources[event["ip"]]["last"])

    def test_low_frequency_probes_survive_module_restart(self):
        with tempfile.TemporaryDirectory(prefix="tnt-guard-test.") as directory:
            state = Path(directory) / "probes.json"
            event = self.event()
            event.update(event="session.leave", rejected=1)
            for i in range(3):
                guard = MODULE.Guard(state=state)
                event["timestamp"] = 1000 + i * 4 * 3600
                blank = event | {"event": "message", "plain_text": "\n"}
                guard.check(blank)
                result = guard.check(event)
                self.assertEqual(result["action"], "ban" if i == 2 else "allow")
            self.assertEqual(state.stat().st_mode & 0o777, 0o600)
            self.assertNotIn("plain_text", state.read_text())

    def test_quiet_readers_and_old_probes_are_not_penalized(self):
        guard = MODULE.Guard()
        event = self.event()
        event["event"] = "session.leave"
        for _ in range(10):
            self.assertEqual(guard.check(event)["action"], "allow")
        event["rejected"] = 1
        for _ in range(4):
            self.assertEqual(guard.check(event)["action"], "allow")
        self.assertFalse(guard.probes)
        for i in range(4):
            event["timestamp"] = 1000 + i * 86401
            guard.check(event | {"event": "message", "plain_text": "\n"})
            self.assertEqual(guard.check(event)["action"], "allow")

    def test_source_memory_is_bounded(self):
        guard = MODULE.Guard({"max_sources": 2})
        for i in range(5):
            event = self.event(plain_text="hello")
            event["ip"] = "203.0.113." + str(i)
            guard.check(event)
        self.assertEqual(len(guard.sources), 2)

    def test_configuration_rejects_unknown_or_unbounded_values(self):
        for config in ({"nickname": 1}, {"burst": 0}, {"max_sources": 4097},
                       {"notice_delay_ms": 30001}, {"burst": True}):
            with self.assertRaises(ValueError):
                MODULE.Guard(config)


if __name__ == "__main__":
    unittest.main()
