#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
python3 - "${TNT_BIN:-$ROOT/../TNT/tnt}" "${PORT:-13820}" "$ROOT/modules/guard-module" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

binary = str(Path(sys.argv[1]).resolve())
port = sys.argv[2]
ssh = ["ssh", "-T", "-e", "none", "-p", port, "-o", "BatchMode=yes",
       "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
       "-o", "LogLevel=ERROR", "-o", "PubkeyAuthentication=no",
       "-o", "SendEnv=-LANG", "-o", "SendEnv=-LC_*", "anonymous@127.0.0.1"]

def wait_for(predicate, description, seconds=8):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.03)
    raise AssertionError(description)

with tempfile.TemporaryDirectory(prefix="tnt-moderation.") as directory:
    state = Path(directory)
    server = None
    clients = []
    log = (state / "server.log").open("w+")
    env = dict(os.environ, TNT_LANG="en", TNT_RATE_LIMIT="1",
               TNT_MAX_CONN_RATE_PER_IP="1024", TNT_MAX_CONN_PER_IP="10",
               TNT_MODULE_PATHS=sys.argv[3], TNT_MODULE_GRANTS="guard-module")
    def start():
        process = subprocess.Popen([binary, "--bind", "127.0.0.1", "-p", port,
                                    "-d", directory], env=env, stdout=log, stderr=log)
        wait_for(lambda: "TNT chat server listening" in (state / "server.log").read_text(),
                 "server did not start", 15)
        return process

    def audit():
        path = state / "security.log"
        if not path.exists():
            return []
        return [json.loads(line) for line in path.read_text().splitlines() if line.endswith("}")]

    def has_event(event, nickname):
        return any(row["event"] == event and row["nickname"] == nickname for row in audit())

    def history():
        path = state / "messages.log"
        return path.read_text() if path.exists() else ""

    def join(name):
        process = subprocess.Popen(ssh, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL)
        clients.append(process)
        process.stdin.write(name.encode() + b"\r")
        process.stdin.flush()
        wait_for(lambda: has_event("session_join", name), "anonymous join failed: " + name)
        return process

    def send(process, content):
        process.stdin.write(content)
        process.stdin.flush()

    def close(process):
        process.terminate()
        process.wait(timeout=5)
        process.stdin.close()

    def command(*args):
        return subprocess.run([binary, "-d", directory, *args], capture_output=True,
                              text=True, timeout=5, check=True)

    try:
        server = start()
        client = join("?")
        send(client, "正常匿名发言 👋\r".encode())
        wait_for(lambda: "正常匿名发言 👋" in history(), "normal Unicode message rejected")
        close(client)
        assert not (state / "bans/127.0.0.1").exists(), "nickname affected moderation"
        print("✓ anonymous question-mark nickname and Unicode messages work")

        for name in ("probe-one", "reader-two", "另一个昵称"):
            client = join(name)
            send(client, b"\n\r")
            wait_for(lambda: has_event("message_rejected", name), "blank probe was not audited")
            close(client)
            wait_for(lambda: has_event("session_leave", name), "probe did not leave")
            assert name not in history(), "empty probe polluted public history"
        wait_for(lambda: (state / "bans/127.0.0.1").exists(), "reconnected probes bypassed ban")
        assert command("--list-bans").stdout.startswith("127.0.0.1 ")
        print("✓ empty probes are suppressed and banned across nickname changes")

        server.terminate()
        server.wait(timeout=5)
        log.seek(0)
        log.truncate()
        server = start()
        blocked = subprocess.run(ssh + ["health"], capture_output=True, timeout=5)
        assert blocked.returncode != 0, "restart lost ban"
        command("--unban", "127.0.0.1")
        health = subprocess.run(ssh + ["health"], capture_output=True, timeout=5)
        assert health.stdout.strip() == b"ok", "operator unban did not take effect"
        print("✓ bans survive restart and operator unban applies live")

        client = join("quiet-reader")
        time.sleep(0.2)
        close(client)
        assert not command("--list-bans").stdout, "quiet reader counted as abuse"
        print("✓ quiet anonymous readers are not penalized")

        client = join("flooder")
        send(client, b"".join(("unique message %d\r" % n).encode() for n in range(30)))
        wait_for(lambda: bool(command("--list-bans").stdout), "message flood did not trigger ban")
        client.wait(timeout=5)
        client.stdin.close()
        accepted = [line for line in history().splitlines() if "|flooder|" in line]
        assert 0 < len(accepted) < 30, "flood was not limited"
        print("✓ flood is limited and the active sender is disconnected")

        command("--unban", "127.0.0.1")
        time.sleep(1.1)
        client = join("idle-reader")
        command("--ban", "127.0.0.1", "--ban-seconds", "60")
        client.wait(timeout=4)
        client.stdin.close()
        command("--unban", "127.0.0.1")
        print("✓ manual bans disconnect existing idle sessions")

        assert (state / "security.log").stat().st_mode & 0o777 == 0o600
        assert "正常匿名发言" not in (state / "security.log").read_text()
        assert all("127.0.0.1" not in line for line in history().splitlines())
        assert all("content" not in row for row in audit())
        print("✓ audit metadata stays private and contains no message bodies")
    except BaseException:
        print((state / "server.log").read_text(), file=sys.stderr)
        print(history(), file=sys.stderr)
        raise
    finally:
        for process in clients:
            if process.poll() is None:
                process.kill()
            process.wait()
            if process.stdin and not process.stdin.closed:
                process.stdin.close()
        if server and server.poll() is None:
            server.terminate()
            server.wait(timeout=5)
        log.close()
PY
