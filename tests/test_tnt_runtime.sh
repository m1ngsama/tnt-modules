#!/bin/sh
# End-to-end compatibility test for the bundled modules and a real TNT server.

set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TNT_ROOT=${TNT_ROOT:-$ROOT/../TNT}
TNT_BIN=${TNT_BIN:-$TNT_ROOT/tnt}
PORT=${PORT:-12482}
STATE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/tnt-modules-runtime.XXXXXX")
SERVER_PID=""
MODULE_PIDS=""
PASS=0

cleanup() {
    if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill -TERM "$SERVER_PID" 2>/dev/null || true
        i=0
        while kill -0 "$SERVER_PID" 2>/dev/null && [ "$i" -lt 100 ]; do
            sleep 0.05
            i=$((i + 1))
        done
        if kill -0 "$SERVER_PID" 2>/dev/null; then
            kill -KILL "$SERVER_PID" 2>/dev/null || true
        fi
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    rm -rf "$STATE_DIR"
}
trap cleanup EXIT INT TERM

fail() {
    echo "FAIL $*" >&2
    if [ -f "$STATE_DIR/server.log" ]; then
        echo "--- TNT server log ---" >&2
        sed -n '1,240p' "$STATE_DIR/server.log" >&2
    fi
    exit 1
}

pass() {
    echo "PASS $*"
    PASS=$((PASS + 1))
}

[ -x "$TNT_BIN" ] || fail "TNT binary is not executable: $TNT_BIN"
command -v ssh >/dev/null 2>&1 || fail "ssh is required"

MODULE_PATHS=""
for name in roll-module flip-module 8ball-module choose-module quote-module; do
    module_dir="$ROOT/modules/$name"
    [ -d "$module_dir" ] || fail "missing module directory: $module_dir"
    if [ -z "$MODULE_PATHS" ]; then
        MODULE_PATHS=$module_dir
    else
        MODULE_PATHS="$MODULE_PATHS:$module_dir"
    fi
done

TNT_LANG=en TNT_RATE_LIMIT=0 TNT_MAX_CONNECTIONS=64 \
    TNT_MAX_CONN_PER_IP=64 TNT_MAX_CONN_RATE_PER_IP=256 \
    TNT_MODULE_PATHS="$MODULE_PATHS" \
    "$TNT_BIN" -p "$PORT" -d "$STATE_DIR" \
    >"$STATE_DIR/server.log" 2>&1 &
SERVER_PID=$!

SSH_OPTS="-n -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectionAttempts=2 -o ConnectTimeout=5 -p $PORT"
health=""
i=0
while [ "$i" -lt 100 ]; do
    kill -0 "$SERVER_PID" 2>/dev/null || fail "TNT exited during startup"
    health=$(ssh $SSH_OPTS localhost health 2>/dev/null || true)
    [ "$health" = "ok" ] && break
    sleep 0.05
    i=$((i + 1))
done
[ "$health" = "ok" ] || fail "TNT health did not become ready"
pass "TNT starts with all five bundled modules"

for name in roll-module flip-module 8ball-module choose-module quote-module; do
    grep -q "module runtime: enabled $name" "$STATE_DIR/server.log" ||
        fail "$name was not enabled"
done
pass "every module completes the TNT handshake"

MODULE_PIDS=$(ps -axo pid=,ppid= | awk -v parent="$SERVER_PID" \
    '$2 == parent { print $1 }')
[ "$(printf '%s\n' "$MODULE_PIDS" | sed '/^$/d' | wc -l | tr -d ' ')" -eq 5 ] ||
    fail "expected five module child processes"
pass "TNT supervises exactly five module processes"

post() {
    message=$1
    output=$(ssh $SSH_OPTS deploycheck@localhost post "$message" 2>/dev/null || true)
    [ "$output" = "posted" ] || fail "post failed for: $message"
}

post "/roll 1d2"
post "/flip"
post "/8ball will the integration pass?"
post "/choose sentinel | sentinel"
post "/quote"
pass "all bundled slash commands are accepted through SSH exec"

tail_output=""
i=0
while [ "$i" -lt 100 ]; do
    tail_output=$(ssh $SSH_OPTS localhost "tail -n 20" 2>/dev/null || true)
    found=0
    for name in roll-module flip-module 8ball-module choose-module quote-module; do
        if printf '%s\n' "$tail_output" | grep -q "module:$name"; then
            found=$((found + 1))
        fi
    done
    [ "$found" -eq 5 ] && break
    sleep 0.05
    i=$((i + 1))
done

for name in roll-module flip-module 8ball-module choose-module quote-module; do
    count=$(printf '%s\n' "$tail_output" | grep -c "module:$name" || true)
    [ "$count" -eq 1 ] || fail "$name produced $count persisted responses, expected one"
done
pass "each command produces exactly one persisted module response"

if grep -E 'module runtime: (failed to enable|disabling)|ignored invalid response' \
        "$STATE_DIR/server.log" >/dev/null; then
    fail "TNT reported a module protocol failure"
fi
pass "TNT reports no invalid, disabled, or failed module"

kill -TERM "$SERVER_PID"
i=0
while kill -0 "$SERVER_PID" 2>/dev/null && [ "$i" -lt 100 ]; do
    sleep 0.05
    i=$((i + 1))
done
kill -0 "$SERVER_PID" 2>/dev/null && fail "TNT did not stop within five seconds"
if wait "$SERVER_PID"; then
    SERVER_PID=""
else
    fail "TNT returned a failure status during graceful shutdown"
fi

for child in $MODULE_PIDS; do
    if kill -0 "$child" 2>/dev/null; then
        fail "module child $child survived TNT shutdown"
    fi
done
pass "graceful shutdown reaps every module process"

echo "$PASS/$PASS core integration checks passed"
