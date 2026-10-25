#!/usr/bin/env python3
import collections
import json
import os
from pathlib import Path
import sys
import tempfile


DEFAULTS = {
    "burst": 8,
    "per_second": 2,
    "per_minute": 30,
    "duplicate_limit": 4,
    "duplicate_window": 10,
    "violation_limit": 5,
    "violation_window": 60,
    "ban_seconds": 900,
    "probe_limit": 3,
    "probe_window": 86400,
    "probe_ban_seconds": 86400,
    "notice_delay_ms": 3000,
    "max_sources": 512,
}
NOTICES = {
    "blank_message": ("Messages must contain visible text.", "消息需要包含可见的文字。"),
    "message_rate": ("You are sending too quickly. Please wait a moment.", "消息发送得太快，请稍后再试。"),
    "duplicate_message": ("Please avoid repeating the same message.", "请不要连续发送相同的消息。"),
    "repeated_empty_probes": ("Repeated empty probes are temporarily blocked.", "此来源因反复发送空白探测消息已被临时封禁。"),
}


class Guard:
    def __init__(self, config=None, state=None):
        self.config = DEFAULTS | (config or {})
        for name, value in self.config.items():
            if name not in DEFAULTS or type(value) is not int or not 1 <= value <= 86400:
                raise ValueError(f"invalid guard setting: {name}")
        if self.config["notice_delay_ms"] > 30000 or self.config["max_sources"] > 4096:
            raise ValueError("guard setting exceeds server bounds")
        self.sources = collections.OrderedDict()
        self.state = state
        self.probes = {}
        if state and state.exists():
            try:
                data = json.loads(state.read_text()[:1024 * 1024])
                if type(data) is not dict or len(data) > self.config["max_sources"]:
                    raise ValueError("invalid probe state")
                for ip, times in data.items():
                    if (type(ip) is not str or type(times) is not list or
                            len(times) > self.config["probe_limit"] or
                            any(type(t) is not int for t in times)):
                        raise ValueError("invalid probe state")
                self.probes = data
            except (OSError, ValueError) as error:
                print(f"guard-module: cannot restore probe state: {error}", file=sys.stderr)

    def save(self):
        if self.state is None:
            return
        descriptor, name = tempfile.mkstemp(prefix=".guard-", dir=self.state.parent)
        try:
            with os.fdopen(descriptor, "w") as stream:
                json.dump(self.probes, stream, separators=(",", ":"))
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(name, self.state)
        finally:
            if os.path.exists(name):
                os.unlink(name)

    def check(self, event):
        config = self.config
        now = event["timestamp"]
        ip = event["ip"]
        result = {"type": "moderation.result", "id": event["id"], "action": "allow",
                  "reason": "accepted", "notice": "", "notice_delay_ms": 0}
        if ip not in self.sources:
            if len(self.sources) >= config["max_sources"]:
                self.sources.popitem(last=False)
            self.sources[ip] = {"tokens": config["burst"], "at": now, "last": None,
                                "copies": 0, "copy_at": now,
                                "messages": collections.deque(), "violations": collections.deque(),
                                "blank_sessions": set()}
        source = self.sources[ip]
        self.sources.move_to_end(ip)
        reason = ""
        seconds = 0
        if event["event"] == "session.join":
            result["notice_delay_ms"] = config["notice_delay_ms"]
        elif event["event"] == "session.leave":
            if (event["accepted"] == 0 and event["rejected"] > 0 and
                    event["session"] in source["blank_sessions"] and
                    event["elapsed_ms"] < config["notice_delay_ms"]):
                times = [t for t in self.probes.get(ip, []) if 0 <= now - t < config["probe_window"]]
                times.append(now)
                self.probes[ip] = times[-config["probe_limit"]:]
                self.probes = {key: value for key, value in self.probes.items()
                               if value and 0 <= now - value[-1] < config["probe_window"]}
                if len(self.probes) > config["max_sources"]:
                    oldest = min(self.probes, key=lambda key: self.probes[key][-1])
                    del self.probes[oldest]
                if len(times) >= config["probe_limit"]:
                    reason, seconds = "repeated_empty_probes", config["probe_ban_seconds"]
                self.save()
            source["blank_sessions"].discard(event["session"])
        elif event["event"] == "message":
            text = event.get("plain_text")
            if text is not None and (not text or all(c.isspace() or c in "\u200b\u200c\u200d\u2060\ufeff" for c in text)):
                reason = "blank_message"
                source["blank_sessions"].add(event["session"])
            source["tokens"] = min(config["burst"], source["tokens"] + max(0, now - source["at"]) * config["per_second"])
            source["at"] = now
            while source["messages"] and now - source["messages"][0] >= 60:
                source["messages"].popleft()
            if not reason:
                if source["tokens"] < 1 or len(source["messages"]) >= config["per_minute"]:
                    reason = "message_rate"
                else:
                    source["tokens"] -= 1
                    if text is not None:
                        if source["last"] != text or now - source["copy_at"] >= config["duplicate_window"]:
                            source.update(last=text, copies=0, copy_at=now)
                        source["copies"] += 1
                        if source["copies"] > config["duplicate_limit"]:
                            reason = "duplicate_message"
                    if not reason:
                        source["messages"].append(now)
            if reason:
                while source["violations"] and now - source["violations"][0] >= config["violation_window"]:
                    source["violations"].popleft()
                source["violations"].append(now)
                if len(source["violations"]) >= config["violation_limit"]:
                    seconds = config["ban_seconds"]
        if reason:
            result.update(action="ban" if seconds else "reject", reason=reason,
                          notice=NOTICES[reason][event.get("language") == "zh"])
            if seconds:
                result["ban_seconds"] = seconds
                source["violations"].clear()
                source["tokens"] = config["burst"]
                source["messages"].clear()
                source["copies"] = 0
        return result


def main():
    config_path = os.environ.get("TNT_GUARD_CONFIG")
    config = json.loads(Path(config_path).read_text()) if config_path else None
    state = Path(os.environ.get("TNT_STATE_DIR", ".")) / "guard-probes.json"
    guard = Guard(config, state)
    for line in sys.stdin:
        event = json.loads(line)
        if event.get("type") == "handshake":
            if event.get("protocol") != "tnt.module.v1":
                print(json.dumps({"type": "error", "code": "unsupported_protocol",
                                  "message": "requires tnt.module.v1"}), flush=True)
                return
            result = {"type": "handshake.ok", "protocol": "tnt.module.v1",
                      "module": {"name": "guard-module", "version": "0.1.0"}}
        elif event.get("type") == "moderation.check":
            result = guard.check(event)
        else:
            result = {"type": "event.ok"}
        print(json.dumps(result, ensure_ascii=False, separators=(",", ":")), flush=True)


if __name__ == "__main__":
    main()
