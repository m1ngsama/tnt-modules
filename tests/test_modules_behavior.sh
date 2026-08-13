#!/bin/sh
# Behavioral and JSONL framing tests for every bundled TNT module.

set -eu

PASS=0
FAIL=0
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
STATE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/tnt-modules-behavior.XXXXXX")
MODULE_TEST_TIMEOUT_SECONDS=${TNT_MODULE_TEST_TIMEOUT_SECONDS:-4}

cleanup() {
    rm -rf "$STATE_DIR"
}
trap cleanup EXIT INT TERM

HS='{"type":"handshake","protocol":"tnt.module.v1","server":{"name":"tnt","version":"1.1.0"}}'
BAD_HS='{"type":"handshake","protocol":"tnt.module.v999","server":{"name":"tnt","version":"1.1.0"}}'
EVENT_OK='^\{"type":"event\.ok"\}$'
UNSUPPORTED_PROTOCOL='^\{"type":"error","code":"unsupported_protocol","message":"requires tnt\.module\.v1"\}$'

pass() {
    echo "PASS $1"
    PASS=$((PASS + 1))
}

fail_case() {
    echo "FAIL $1"
    [ -z "${2:-}" ] || printf '%s\n' "$2"
    FAIL=$((FAIL + 1))
}

run_module_with_timeout() {
    module_output=$1
    module_dir=$2
    module_entry=$3
    module_input=$4
    module_path_prefix=$5
    module_timeout=$6

    case "$module_dir" in
        /*) ;;
        *) module_dir="$ROOT/$module_dir" ;;
    esac

    python3 - "$module_output" "$module_dir" "$module_entry" \
        "$module_input" "$module_path_prefix" "$module_timeout" <<'PY'
import os
import pathlib
import signal
import subprocess
import sys
import time

output_path = pathlib.Path(sys.argv[1])
module_dir = pathlib.Path(sys.argv[2])
entrypoint = sys.argv[3]
input_path = pathlib.Path(sys.argv[4])
path_prefix = sys.argv[5]
try:
    timeout = float(sys.argv[6])
except ValueError:
    raise SystemExit(f"invalid module timeout: {sys.argv[6]!r}")
if timeout <= 0:
    raise SystemExit(f"module timeout must be positive, got {timeout}")

environment = os.environ.copy()
if path_prefix:
    environment["PATH"] = path_prefix + os.pathsep + environment.get("PATH", "")


def signal_group(process, process_signal):
    try:
        os.killpg(process.pid, process_signal)
    except (ProcessLookupError, PermissionError):
        pass


def group_exists(process_group):
    try:
        os.killpg(process_group, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


try:
    payload = input_path.read_bytes()
    process = subprocess.Popen(
        [str(module_dir / entrypoint)],
        cwd=str(module_dir),
        env=environment,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
except OSError as exc:
    print(f"module invocation could not start {module_dir / entrypoint}: {exc}",
          file=sys.stderr)
    raise SystemExit(126)

timed_out = False
try:
    stdout, stderr = process.communicate(payload, timeout=timeout)
except subprocess.TimeoutExpired:
    timed_out = True
    signal_group(process, signal.SIGTERM)
    time.sleep(0.1)
    # Always escalate for the whole group: the direct child may exit while a
    # descendant that closed its stdio remains alive.
    signal_group(process, signal.SIGKILL)
    try:
        stdout, stderr = process.communicate(timeout=1.0)
    except subprocess.TimeoutExpired:
        # A process that escaped the group must not hold this test indefinitely.
        if process.stdout is not None:
            process.stdout.close()
        if process.stderr is not None:
            process.stderr.close()
        try:
            process.wait(timeout=1.0)
        except subprocess.TimeoutExpired:
            pass
        stdout, stderr = b"", b""

output_path.write_bytes(stdout)
if stderr and (timed_out or process.returncode != 0):
    sys.stderr.buffer.write(stderr)

if timed_out:
    cleanup_deadline = time.monotonic() + 1.0
    while group_exists(process.pid) and time.monotonic() < cleanup_deadline:
        time.sleep(0.01)
    if group_exists(process.pid):
        print(f"module timeout cleanup left process group {process.pid}",
              file=sys.stderr)
        raise SystemExit(125)
    print(
        f"module invocation timed out after {timeout:.3f}s: "
        f"{module_dir / entrypoint}",
        file=sys.stderr,
    )
    raise SystemExit(124)

# A module could exit after daemonizing a descendant that closed the captured
# pipes. Remove any such process before returning from a successful invocation.
if group_exists(process.pid):
    signal_group(process, signal.SIGTERM)
    time.sleep(0.05)
    signal_group(process, signal.SIGKILL)
if process.returncode != 0:
    print(
        f"module invocation exited with status {process.returncode}: "
        f"{module_dir / entrypoint}",
        file=sys.stderr,
    )
    raise SystemExit(1)
PY
}

# module_out OUTPUT MODULE_DIR ENTRYPOINT LINE...
module_out() {
    module_output=$1
    module_dir=$2
    module_entry=$3
    shift 3
    module_input="$module_output.input"
    printf '%s\n' "$@" >"$module_input"
    run_module_with_timeout "$module_output" "$module_dir" "$module_entry" \
        "$module_input" "" "$MODULE_TEST_TIMEOUT_SECONDS"
}

# module_out_file OUTPUT MODULE_DIR ENTRYPOINT INPUT_FILE
module_out_file() {
    module_output=$1
    module_dir=$2
    module_entry=$3
    module_input=$4
    run_module_with_timeout "$module_output" "$module_dir" "$module_entry" \
        "$module_input" "" "$MODULE_TEST_TIMEOUT_SECONDS"
}

# As above, with a fixture command directory prepended to PATH.
module_out_file_with_path() {
    module_output=$1
    module_dir=$2
    module_entry=$3
    module_input=$4
    module_path_prefix=$5
    run_module_with_timeout "$module_output" "$module_dir" "$module_entry" \
        "$module_input" "$module_path_prefix" "$MODULE_TEST_TIMEOUT_SECONDS"
}

make_choose_seed_fixture() {
    fixture_bin=$1
    mkdir -p "$fixture_bin"
    # Find a seed for this platform's awk that selects the first of two options.
    fixture_seed=$(LC_ALL=C awk '
        BEGIN {
          for (seed = 1; seed <= 10000; seed++) {
            srand(seed)
            if (int(rand() * 2) == 0) {
              print seed
              exit
            }
          }
          exit 1
        }
    ')
    {
        printf '#!/bin/sh\n'
        printf 'printf " %%s\\n" "%s"\n' "$fixture_seed"
    } >"$fixture_bin/od"
    chmod +x "$fixture_bin/od"
}

# Construct the simple message.created inputs used below. Test strings passed to
# this helper deliberately contain no JSON escapes; escaped-string handling has
# separate protocol tests in TNT core.
event() {
    event_sender=$1
    event_text=$2
    printf '{"type":"message.created","message":{"sender":"%s","plain_text":"%s"}}' \
        "$event_sender" "$event_text"
}

validate_jsonl() {
    python3 - "$1" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
data = path.read_bytes()
if not data:
    raise SystemExit("stdout was empty")
if not data.endswith(b"\n"):
    raise SystemExit("stdout was not newline-terminated")

try:
    text = data.decode("utf-8")
except UnicodeDecodeError as exc:
    raise SystemExit(f"stdout was not UTF-8: {exc}")

for number, line in enumerate(text.splitlines(), 1):
    if not line:
        raise SystemExit(f"line {number} was empty")
    try:
        value = json.loads(line)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"line {number} was not valid JSON: {exc.msg}")
    if not isinstance(value, dict):
        raise SystemExit(f"line {number} was not a JSON object")
PY
}

# Assert exact record count, valid UTF-8 JSON objects, and one regex per record.
# This deliberately checks records by position so a later event.ok cannot hide a
# missing completion record for an earlier event.
assert_json_lines() {
    assert_label=$1
    assert_file=$2
    shift 2
    assert_expected_count=$#

    if assert_json_error=$(validate_jsonl "$assert_file" 2>&1); then
        :
    else
        fail_case "$assert_label" "$assert_json_error
$(nl -ba "$assert_file")"
        return
    fi

    assert_actual_count=$(awk 'END { print NR + 0 }' "$assert_file")
    if [ "$assert_actual_count" -ne "$assert_expected_count" ]; then
        fail_case "$assert_label" "expected $assert_expected_count JSON records, got $assert_actual_count
$(nl -ba "$assert_file")"
        return
    fi

    assert_index=1
    for assert_pattern in "$@"; do
        assert_line=$(sed -n "${assert_index}p" "$assert_file")
        if ! printf '%s\n' "$assert_line" | grep -Eq "$assert_pattern"; then
            fail_case "$assert_label" "record $assert_index did not match: $assert_pattern
$(nl -ba "$assert_file")"
            return
        fi
        assert_index=$((assert_index + 1))
    done

    pass "$assert_label"
}

assert_handshakes() {
    handshake_label=$1
    handshake_dir=$2
    handshake_entry=$3
    handshake_name=$4

    handshake_file="$STATE_DIR/$handshake_label-handshake.out"
    module_out "$handshake_file" "$handshake_dir" "$handshake_entry" "$HS"
    assert_json_lines "$handshake_label: supported handshake" "$handshake_file" \
        "^\\{\"type\":\"handshake\\.ok\",\"protocol\":\"tnt\\.module\\.v1\",\"module\":\\{\"name\":\"$handshake_name\",\"version\":\"0\\.1\\.0\"\\}\\}$"

    handshake_file="$STATE_DIR/$handshake_label-bad-handshake.out"
    module_out "$handshake_file" "$handshake_dir" "$handshake_entry" "$BAD_HS"
    assert_json_lines "$handshake_label: unsupported protocol" "$handshake_file" \
        "$UNSUPPORTED_PROTOCOL"
}

assert_command_event() {
    command_label=$1
    command_dir=$2
    command_entry=$3
    command_input=$4
    command_pattern=$5

    command_file="$STATE_DIR/$command_label-command.out"
    module_out "$command_file" "$command_dir" "$command_entry" "$command_input"
    assert_json_lines "$command_label: command completes its event" "$command_file" \
        "$command_pattern" "$EVENT_OK"
}

assert_noop_event() {
    noop_label=$1
    noop_dir=$2
    noop_entry=$3
    noop_input=$4
    noop_description=$5

    noop_file="$STATE_DIR/$noop_label-$noop_description.out"
    module_out "$noop_file" "$noop_dir" "$noop_entry" "$noop_input"
    assert_json_lines "$noop_label: $noop_description is only a no-op" \
        "$noop_file" "$EVENT_OK"
}

write_boundary_events() {
    boundary_file=$1
    boundary_case=$2
    boundary_count=$3
    python3 - "$boundary_file" "$boundary_case" "$boundary_count" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
case = sys.argv[2]
count = int(sys.argv[3])

if case == "echo-ascii":
    sender = "abcdefghijklmnopqrst"
    plain_text = "a" * 1023
elif case == "echo-utf8":
    sender = "abcdefghijklmnopqrst"
    # The four-byte emoji cannot fit in the three bytes left after the prefix.
    plain_text = ("中" * 338) + "🙂"
elif case == "choose-ascii":
    sender = "abcdefghijklmnopqrst"
    plain_text = "/choose " + ("a" * 1008) + " | x"
elif case == "choose-utf8":
    sender = "abcdefghijklmnopqrs"
    # The chosen long option exceeds the response budget, and the available
    # output space is not divisible by this option's three-byte code point.
    plain_text = "/choose " + ("中" * 335) + " | x"
else:
    raise SystemExit(f"unknown boundary case: {case}")

event = {
    "type": "message.created",
    "message": {"sender": sender, "plain_text": plain_text},
}
line = json.dumps(event, ensure_ascii=False, separators=(",", ":"))
path.write_text((line + "\n") * count, encoding="utf-8")
PY
}

assert_bounded_actions() {
    boundary_label=$1
    boundary_file=$2
    boundary_case=$3
    boundary_count=$4

    if boundary_error=$(python3 - "$boundary_file" "$boundary_case" "$boundary_count" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
case = sys.argv[2]
expected_events = int(sys.argv[3])


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate key: {key}")
        result[key] = value
    return result


data = path.read_bytes()
if not data.endswith(b"\n"):
    raise SystemExit("stdout was not newline-terminated")
try:
    output = data.decode("utf-8")
except UnicodeDecodeError as exc:
    raise SystemExit(f"stdout split a UTF-8 code point: {exc}")

try:
    records = [
        json.loads(line, object_pairs_hook=unique_object)
        for line in output.splitlines()
    ]
except (json.JSONDecodeError, ValueError) as exc:
    raise SystemExit(f"stdout was not strict JSONL: {exc}")

if len(records) != expected_events * 2:
    raise SystemExit(
        f"expected {expected_events * 2} records, got {len(records)}"
    )

actions = []
for index in range(expected_events):
    action = records[index * 2]
    completion = records[(index * 2) + 1]
    if action.get("type") != "message.create":
        raise SystemExit(f"event {index + 1} did not emit message.create")
    if completion != {"type": "event.ok"}:
        raise SystemExit(f"event {index + 1} was not terminated by event.ok")
    plain_text = action.get("plain_text")
    if not isinstance(plain_text, str) or not plain_text:
        raise SystemExit(f"event {index + 1} omitted plain_text")
    encoded = plain_text.encode("utf-8")
    if len(encoded) > 1023:
        raise SystemExit(
            f"event {index + 1} emitted {len(encoded)} plain_text bytes"
        )
    if any(ord(character) < 32 or ord(character) == 127
           for character in plain_text):
        raise SystemExit(f"event {index + 1} emitted a control character")
    actions.append(plain_text)

if case == "echo-ascii":
    expected = "echo: " + ("a" * 1017)
    if actions != [expected] or len(actions[0].encode("utf-8")) != 1023:
        raise SystemExit("ASCII echo was not truncated at exactly 1023 bytes")
elif case == "echo-utf8":
    expected = "echo: " + ("中" * 338)
    if actions != [expected] or len(actions[0].encode("utf-8")) != 1020:
        raise SystemExit("UTF-8 echo truncation did not preserve code-point boundaries")
elif case == "choose-ascii":
    expected = "🤔 abcdefghijklmnopqrst chose: " + ("a" * 990)
    if expected not in actions or len(expected.encode("utf-8")) != 1023:
        raise SystemExit("long ASCII option was not observed safely truncated")
elif case == "choose-utf8":
    expected = "🤔 abcdefghijklmnopqrs chose: " + ("中" * 330)
    if expected not in actions or len(expected.encode("utf-8")) != 1022:
        raise SystemExit("long UTF-8 option was not observed safely truncated")
else:
    raise SystemExit(f"unknown boundary case: {case}")
PY
    ); then
        pass "$boundary_label"
    else
        fail_case "$boundary_label" "$boundary_error
$(nl -ba "$boundary_file")"
    fi
}

write_choose_literal_event() {
    literal_file=$1
    literal_case=$2
    python3 - "$literal_file" "$literal_case" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
case = sys.argv[2]
if case == "backslash-t":
    option = r"C:\tmp"
elif case == "backslash-n":
    option = r"x\ny"
else:
    raise SystemExit(f"unknown literal case: {case}")

event = {
    "type": "message.created",
    "message": {
        "sender": "dan",
        "plain_text": f"/choose {option} | {option}",
    },
}
path.write_text(
    json.dumps(event, ensure_ascii=False, separators=(",", ":")) + "\n",
    encoding="utf-8",
)
PY
}

assert_choose_literal() {
    literal_label=$1
    literal_file=$2
    literal_case=$3

    if literal_error=$(python3 - "$literal_file" "$literal_case" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
case = sys.argv[2]
option = r"C:\tmp" if case == "backslash-t" else r"x\ny"
expected = f"🤔 dan chose: {option}"

try:
    records = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]
except (UnicodeDecodeError, json.JSONDecodeError) as exc:
    raise SystemExit(f"output was not UTF-8 JSONL: {exc}")

if records != [
    {"type": "message.create", "plain_text": expected},
    {"type": "event.ok"},
]:
    raise SystemExit(f"expected literal {expected!r}, got {records!r}")
PY
    ); then
        pass "$literal_label"
    else
        fail_case "$literal_label" "$literal_error
$(nl -ba "$literal_file")"
    fi
}

assert_choose_escaped() {
    escaped_label=$1
    escaped_file=$2

    if escaped_error=$(python3 - "$escaped_file" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
expected = '🤔 d"an chose: ' + r'say "hi" C:\tmp'
try:
    records = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]
except (UnicodeDecodeError, json.JSONDecodeError) as exc:
    raise SystemExit(f"output was not UTF-8 JSONL: {exc}")

if records != [
    {"type": "message.create", "plain_text": expected},
    {"type": "event.ok"},
]:
    raise SystemExit(f"expected escaped text {expected!r}, got {records!r}")
PY
    ); then
        pass "$escaped_label"
    else
        fail_case "$escaped_label" "$escaped_error
$(nl -ba "$escaped_file")"
    fi
}

write_awk_literal_events() {
    literal_file=$1
    literal_module=$2
    python3 - "$literal_file" "$literal_module" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
module = sys.argv[2]
sender = r"a\n-\t-\r-\b-\f-\052-\q-\\-z"
commands = {
    "roll": ["/roll d6", r"/roll \1446"],
    "flip": ["/flip"],
    "8ball": ["/8ball question"],
}
try:
    plain_texts = commands[module]
except KeyError:
    raise SystemExit(f"unknown literal awk module: {module}")

events = [
    {
        "type": "message.created",
        "message": {"sender": sender, "plain_text": plain_text},
    }
    for plain_text in plain_texts
]
path.write_text(
    "".join(
        json.dumps(event, ensure_ascii=False, separators=(",", ":")) + "\n"
        for event in events
    ),
    encoding="utf-8",
)
PY
}

assert_awk_literals() {
    literal_label=$1
    literal_file=$2
    literal_module=$3

    if literal_error=$(python3 - "$literal_file" "$literal_module" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
module = sys.argv[2]
sender = r"a\n-\t-\r-\b-\f-\052-\q-\\-z"

try:
    records = [
        json.loads(line)
        for line in path.read_text(encoding="utf-8").splitlines()
    ]
except (UnicodeDecodeError, json.JSONDecodeError) as exc:
    raise SystemExit(f"output was not UTF-8 JSONL: {exc}")

expected_record_count = 4 if module == "roll" else 2
if len(records) != expected_record_count:
    raise SystemExit(
        f"expected {expected_record_count} records, got {len(records)}: {records!r}"
    )
if records[1] != {"type": "event.ok"}:
    raise SystemExit(f"literal sender event was not completed: {records[1]!r}")

action = records[0]
if set(action) != {"type", "plain_text"} or action["type"] != "message.create":
    raise SystemExit(f"literal sender event did not create one message: {action!r}")
plain_text = action["plain_text"]
if not isinstance(plain_text, str):
    raise SystemExit(f"literal sender reply was not text: {plain_text!r}")

if module == "roll":
    prefix = f"🎲 {sender} rolled d6 → "
    if not plain_text.startswith(prefix):
        raise SystemExit(f"literal sender changed in roll reply: {plain_text!r}")
    result = plain_text.removeprefix(prefix)
    if not result.isascii() or not result.isdigit() or not 1 <= int(result) <= 6:
        raise SystemExit(f"roll result was invalid: {result!r}")
    if records[3] != {"type": "event.ok"}:
        raise SystemExit(f"literal spec event was not completed: {records[3]!r}")
    spec_action = records[2]
    if spec_action.get("type") != "message.create" or \
       "roll usage:" not in spec_action.get("plain_text", ""):
        raise SystemExit(
            "literal \\144 dice spec was interpreted as d6 instead of rejected: "
            f"{spec_action!r}"
        )
elif module == "flip":
    expected = {
        f"🪙 {sender} flipped → heads",
        f"🪙 {sender} flipped → tails",
    }
    if plain_text not in expected:
        raise SystemExit(f"literal sender changed in flip reply: {plain_text!r}")
elif module == "8ball":
    prefix = f"🎱 {sender}: "
    if not plain_text.startswith(prefix) or plain_text == prefix:
        raise SystemExit(f"literal sender changed in 8ball reply: {plain_text!r}")
else:
    raise SystemExit(f"unknown literal awk module: {module}")
PY
    ); then
        pass "$literal_label"
    else
        fail_case "$literal_label" "$literal_error
$(nl -ba "$literal_file")"
    fi
}

assert_json_escape_semantics() {
    escape_label=$1
    escape_dir=$2
    escape_entry=$3
    escape_file="$STATE_DIR/$escape_label-json-escape.out"

    if (
        cd "$ROOT/$escape_dir"
        ENTRYPOINT=$escape_entry /bin/sh -s <<'SH'
. "./$ENTRYPOINT" </dev/null
value=$(printf 'quote=" slash=\\ tab=\t backspace=\b formfeed=\f carriage=\r newline=\n control=\001 delete=\177 utf8=🙂')
json_escape "$value"
SH
    ) >"$escape_file" 2>"$escape_file.err"; then
        :
    else
        fail_case "$escape_label: JSON escaping is portable" \
            "$(cat "$escape_file.err")"
        return
    fi

    if escape_error=$(python3 - "$escape_file" <<'PY'
import json
import pathlib
import sys

escaped = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
expected = (
    'quote=" slash=\\ tab=\t backspace=\b formfeed=\f carriage=\r '
    'newline=\n control=\x01 delete=\x7f utf8=🙂'
)
try:
    decoded = json.loads(f'"{escaped}"')
except json.JSONDecodeError as exc:
    raise SystemExit(f"escaped body was not valid JSON string content: {exc}")
if decoded != expected:
    raise SystemExit(f"expected {expected!r}, got {decoded!r}; escaped={escaped!r}")
if any(ord(character) < 32 or ord(character) == 127 for character in escaped):
    raise SystemExit(f"escaped body retained a raw control: {escaped!r}")
PY
    ); then
        pass "$escape_label: JSON escaping is portable"
    else
        fail_case "$escape_label: JSON escaping is portable" "$escape_error"
    fi
}

assert_parser_result() {
    parser_label=$1
    parser_expected_status=$2
    parser_expected_output=$3
    parser_input=$4
    parser_scope=$5
    parser_key=$6
    parser_file="$STATE_DIR/parser-$parser_label.out"
    parser_status=0

    printf '%s\n' "$parser_input" | \
        LC_ALL=C awk -v scope="$parser_scope" -v key="$parser_key" \
            -f "$ROOT/scripts/module_json.awk" >"$parser_file" || \
        parser_status=$?
    parser_output=$(cat "$parser_file")
    if [ "$parser_status" -eq "$parser_expected_status" ] && \
       [ "$parser_output" = "$parser_expected_output" ]; then
        pass "JSON parser: $parser_label"
    else
        fail_case "JSON parser: $parser_label" \
            "expected status/output $parser_expected_status/$parser_expected_output, got $parser_status/$parser_output"
    fi
}

echo "=== TNT Modules Behavior Tests ==="

hang_module_dir="$STATE_DIR/hang-module"
hang_input="$STATE_DIR/hang-module.in"
hang_output="$STATE_DIR/hang-module.out"
hang_error="$STATE_DIR/hang-module.err"
hang_child_pid_file="$STATE_DIR/hang-child.pid"
mkdir -p "$hang_module_dir"
printf '%s\n' '{"type":"handshake","protocol":"tnt.module.v1"}' >"$hang_input"
cat >"$hang_module_dir/hang-module.sh" <<'SH'
#!/bin/sh
(
    trap '' TERM
    while :; do
        sleep 60
    done
) &
child_pid=$!
printf '%s\n' "$child_pid" >"$HANG_CHILD_PID_FILE"
printf '%s\n' ready >"$HANG_READY_FILE"
trap '' TERM
wait "$child_pid"
SH
chmod +x "$hang_module_dir/hang-module.sh"

HANG_CHILD_PID_FILE=$hang_child_pid_file
HANG_READY_FILE="$STATE_DIR/hang-ready"
export HANG_CHILD_PID_FILE HANG_READY_FILE
hang_status=0
run_module_with_timeout "$hang_output" "$hang_module_dir" hang-module.sh \
    "$hang_input" "" 2.0 2>"$hang_error" || hang_status=$?
unset HANG_CHILD_PID_FILE HANG_READY_FILE

hang_child_alive=0
if [ -s "$hang_child_pid_file" ]; then
    hang_child_pid=$(cat "$hang_child_pid_file")
    if kill -0 "$hang_child_pid" 2>/dev/null; then
        hang_child_alive=1
        kill -9 "$hang_child_pid" 2>/dev/null || true
    fi
else
    hang_child_pid=missing
fi

if [ "$hang_status" -eq 124 ] && [ -s "$STATE_DIR/hang-ready" ] && \
   [ "$hang_child_alive" -eq 0 ] && \
   grep -q 'module invocation timed out after 2.000s' "$hang_error"; then
    pass "module runner times out and removes descendant processes"
else
    fail_case "module runner times out and removes descendant processes" \
        "status=$hang_status child=$hang_child_pid child_alive=$hang_child_alive
$(cat "$hang_error")"
fi

if "$ROOT/scripts/sync_module_json.sh" --check; then
    pass "shared JSON parser copies are in sync"
else
    fail_case "shared JSON parser copies are in sync"
fi

sync_fixture="$STATE_DIR/sync-fixture"
mkdir -p "$sync_fixture/examples/symlink-module" "$sync_fixture/scripts"
cp "$ROOT/scripts/sync_module_json.sh" "$sync_fixture/scripts/"
cp "$ROOT/scripts/module_json.awk" "$sync_fixture/scripts/"
printf '%s\n' '{}' >"$sync_fixture/examples/symlink-module/tnt-module.json"
printf '%s\n' sentinel >"$sync_fixture/sentinel"
ln -s ../../sentinel "$sync_fixture/examples/symlink-module/module_json.awk"
if "$sync_fixture/scripts/sync_module_json.sh" >/dev/null 2>&1; then
    fail_case "shared JSON parser sync rejects symlink destinations"
elif [ "$(cat "$sync_fixture/sentinel")" = sentinel ]; then
    pass "shared JSON parser sync rejects symlink destinations"
else
    fail_case "shared JSON parser sync rejects symlink destinations" \
        "symlink target was modified"
fi

sync_directory_fixture="$STATE_DIR/sync-directory-fixture"
mkdir -p "$sync_directory_fixture/examples" \
    "$sync_directory_fixture/external-module" "$sync_directory_fixture/scripts"
cp "$ROOT/scripts/sync_module_json.sh" "$sync_directory_fixture/scripts/"
cp "$ROOT/scripts/module_json.awk" "$sync_directory_fixture/scripts/"
printf '%s\n' '{}' \
    >"$sync_directory_fixture/external-module/tnt-module.json"
printf '%s\n' sentinel \
    >"$sync_directory_fixture/external-module/module_json.awk"
ln -s ../external-module "$sync_directory_fixture/examples/linked-module"
if "$sync_directory_fixture/scripts/sync_module_json.sh" >/dev/null 2>&1; then
    fail_case "shared JSON parser sync rejects symlink module directories"
elif [ "$(cat "$sync_directory_fixture/external-module/module_json.awk")" = sentinel ]; then
    pass "shared JSON parser sync rejects symlink module directories"
else
    fail_case "shared JSON parser sync rejects symlink module directories" \
        "linked module outside the managed tree was modified"
fi

sync_hardlink_fixture="$STATE_DIR/sync-hardlink-fixture"
mkdir -p "$sync_hardlink_fixture/examples/hardlink-module" \
    "$sync_hardlink_fixture/scripts"
cp "$ROOT/scripts/sync_module_json.sh" "$sync_hardlink_fixture/scripts/"
cp "$ROOT/scripts/module_json.awk" "$sync_hardlink_fixture/scripts/"
printf '%s\n' '{}' \
    >"$sync_hardlink_fixture/examples/hardlink-module/tnt-module.json"
printf '%s\n' sentinel >"$sync_hardlink_fixture/hardlink-peer"
ln "$sync_hardlink_fixture/hardlink-peer" \
    "$sync_hardlink_fixture/examples/hardlink-module/module_json.awk"
if "$sync_hardlink_fixture/scripts/sync_module_json.sh" >/dev/null 2>&1 && \
   [ "$(cat "$sync_hardlink_fixture/hardlink-peer")" = sentinel ] && \
   cmp -s "$sync_hardlink_fixture/scripts/module_json.awk" \
       "$sync_hardlink_fixture/examples/hardlink-module/module_json.awk"; then
    pass "shared JSON parser sync atomically replaces hard links"
else
    fail_case "shared JSON parser sync atomically replaces hard links"
fi
assert_parser_result empty-string 0 '' \
    '{"message":{"plain_text":""}}' message plain_text
assert_parser_result absent-field 1 '' \
    '{"message":{}}' message plain_text
assert_parser_result null-field 1 '' \
    '{"message":{"plain_text":null}}' message plain_text
assert_parser_result invalid-json 2 '' \
    '{"message":{"plain_text":"broken"}' message plain_text
assert_parser_result duplicate-key 2 '' \
    '{"message":{"plain_text":"one","plain_text":"two"}}' message plain_text
assert_parser_result escaped-unicode 0 'é' \
    '{"message":{"plain_text":"\u00e9"}}' message plain_text
assert_parser_result escaped-surrogate-pair 0 '🙂' \
    '{"message":{"plain_text":"\ud83d\ude42"}}' message plain_text
assert_parser_result escaped-control 2 '' \
    '{"message":{"plain_text":"unsafe\u0001text"}}' message plain_text
assert_parser_result escaped-newline 2 '' \
    '{"message":{"plain_text":"unsafe\ntext"}}' message plain_text
assert_parser_result unrelated-escaped-control 0 '/flip' \
    '{"metadata":{"note":"line\nwith\ttabs\u0001"},"message":{"plain_text":"/flip"}}' message plain_text

parser_invalid_utf8_input="$STATE_DIR/parser-invalid-utf8.in"
parser_invalid_utf8_output="$STATE_DIR/parser-invalid-utf8.out"
python3 - "$parser_invalid_utf8_input" <<'PY'
import pathlib
import sys

pathlib.Path(sys.argv[1]).write_bytes(
    b'{"message":{"plain_text":"invalid-\xc3("}}\n'
)
PY
parser_invalid_utf8_status=0
LC_ALL=C awk -v scope=message -v key=plain_text \
    -f "$ROOT/scripts/module_json.awk" \
    <"$parser_invalid_utf8_input" >"$parser_invalid_utf8_output" || \
    parser_invalid_utf8_status=$?
if [ "$parser_invalid_utf8_status" -eq 2 ] && \
   [ ! -s "$parser_invalid_utf8_output" ]; then
    pass "JSON parser: invalid-utf8"
else
    fail_case "JSON parser: invalid-utf8" \
        "expected status 2 with no output, got $parser_invalid_utf8_status"
fi

assert_json_escape_semantics roll modules/roll-module roll-module.sh
assert_json_escape_semantics flip modules/flip-module flip-module.sh
assert_json_escape_semantics 8ball modules/8ball-module 8ball-module.sh
assert_json_escape_semantics choose modules/choose-module choose-module.sh
assert_json_escape_semantics quote modules/quote-module quote-module.sh
assert_json_escape_semantics echo examples/echo-module echo-module.sh

# --- roll-module ---
assert_handshakes roll modules/roll-module roll-module.sh roll-module
assert_command_event roll modules/roll-module roll-module.sh \
    "$(event alice '/roll 2d6+3')" \
    '^\{"type":"message\.create","plain_text":"🎲 alice rolled 2d6\+3 → .* = [-0-9]+"\}$'
assert_noop_event roll modules/roll-module roll-module.sh \
    "$(event other 'hello there')" normal-message
assert_noop_event roll modules/roll-module roll-module.sh \
    "$(event other '/roller d6')" command-boundary
assert_noop_event roll modules/roll-module roll-module.sh \
    '{"type":"presence.updated","metadata":{"type":"message.created"},"message":{"sender":"other","plain_text":"/roll d20"}}' unknown-event

roll_awk_literal_input="$STATE_DIR/roll-awk-literals.in"
roll_awk_literal_output="$STATE_DIR/roll-awk-literals.out"
write_awk_literal_events "$roll_awk_literal_input" roll
module_out_file "$roll_awk_literal_output" \
    modules/roll-module roll-module.sh "$roll_awk_literal_input"
assert_awk_literals "roll: awk preserves literal sender and dice spec escapes" \
    "$roll_awk_literal_output" roll

# Invalid dice syntax is a user-visible reply and must still terminate the event.
roll_invalid_file="$STATE_DIR/roll-invalid-spec.out"
module_out "$roll_invalid_file" modules/roll-module roll-module.sh \
    "$(event alice '/roll 21d6')"
assert_json_lines "roll: invalid spec completes its event" "$roll_invalid_file" \
    '^\{"type":"message\.create","plain_text":"🎲 roll usage:.*"\}$' "$EVENT_OK"

# --- flip-module ---
assert_handshakes flip modules/flip-module flip-module.sh flip-module
assert_command_event flip modules/flip-module flip-module.sh \
    "$(event bob /flip)" \
    '^\{"type":"message\.create","plain_text":"🪙 bob flipped → (heads|tails)"\}$'
assert_command_event flip-with-extension modules/flip-module flip-module.sh \
    '{"type":"message.created","metadata":{"note":"line\nwith\ttabs\u0001"},"message":{"sender":"bob","plain_text":"/flip"}}' \
    '^\{"type":"message\.create","plain_text":"🪙 bob flipped → (heads|tails)"\}$'
assert_noop_event flip modules/flip-module flip-module.sh \
    "$(event other plain)" normal-message
assert_noop_event flip modules/flip-module flip-module.sh \
    "$(event other /flipper)" command-boundary
assert_noop_event flip modules/flip-module flip-module.sh \
    '{"type":"presence.updated","metadata":{"type":"message.created"},"message":{"sender":"other","plain_text":"/flip"}}' unknown-event

flip_awk_literal_input="$STATE_DIR/flip-awk-literals.in"
flip_awk_literal_output="$STATE_DIR/flip-awk-literals.out"
write_awk_literal_events "$flip_awk_literal_input" flip
module_out_file "$flip_awk_literal_output" \
    modules/flip-module flip-module.sh "$flip_awk_literal_input"
assert_awk_literals "flip: awk preserves literal sender escapes" \
    "$flip_awk_literal_output" flip

# --- 8ball-module ---
assert_handshakes 8ball modules/8ball-module 8ball-module.sh 8ball-module
assert_command_event 8ball modules/8ball-module 8ball-module.sh \
    "$(event cara '/8ball will it work?')" \
    '^\{"type":"message\.create","plain_text":"🎱 cara: .+"\}$'
assert_noop_event 8ball modules/8ball-module 8ball-module.sh \
    "$(event other plain)" normal-message
assert_noop_event 8ball modules/8ball-module 8ball-module.sh \
    "$(event other '/8balls no')" command-boundary
assert_noop_event 8ball modules/8ball-module 8ball-module.sh \
    '{"type":"presence.updated","metadata":{"type":"message.created"},"message":{"sender":"other","plain_text":"/8ball spoof?"}}' unknown-event

eightball_awk_literal_input="$STATE_DIR/8ball-awk-literals.in"
eightball_awk_literal_output="$STATE_DIR/8ball-awk-literals.out"
write_awk_literal_events "$eightball_awk_literal_input" 8ball
module_out_file "$eightball_awk_literal_output" \
    modules/8ball-module 8ball-module.sh "$eightball_awk_literal_input"
assert_awk_literals "8ball: awk preserves literal sender escapes" \
    "$eightball_awk_literal_output" 8ball

# --- choose-module ---
assert_handshakes choose modules/choose-module choose-module.sh choose-module
assert_command_event choose modules/choose-module choose-module.sh \
    "$(event dan '/choose tea | coffee | water')" \
    '^\{"type":"message\.create","plain_text":"🤔 dan chose: (tea|coffee|water)"\}$'
assert_noop_event choose modules/choose-module choose-module.sh \
    "$(event other plain)" normal-message
assert_noop_event choose modules/choose-module choose-module.sh \
    "$(event other '/chooser tea | coffee')" command-boundary
assert_noop_event choose modules/choose-module choose-module.sh \
    '{"type":"presence.updated","metadata":{"type":"message.created"},"message":{"sender":"other","plain_text":"/choose tea | coffee"}}' unknown-event

choose_usage_file="$STATE_DIR/choose-usage.out"
module_out "$choose_usage_file" modules/choose-module choose-module.sh \
    "$(event dan '/choose onlyone')"
assert_json_lines "choose: too few options completes its event" \
    "$choose_usage_file" \
    '^\{"type":"message\.create","plain_text":"🤔 choose usage:.*"\}$' "$EVENT_OK"

choose_escaped_file="$STATE_DIR/choose-escaped.out"
module_out "$choose_escaped_file" modules/choose-module choose-module.sh \
    '{"type":"message.created","message":{"sender":"d\"an","plain_text":"/choose say \"hi\" C:\\tmp | say \"hi\" C:\\tmp"}}'
assert_choose_escaped "choose: escaped quotes and backslashes survive parsing" \
    "$choose_escaped_file"

for literal_case in backslash-t backslash-n; do
    choose_literal_input="$STATE_DIR/choose-$literal_case.in"
    choose_literal_output="$STATE_DIR/choose-$literal_case.out"
    write_choose_literal_event "$choose_literal_input" "$literal_case"
    module_out_file "$choose_literal_output" \
        modules/choose-module choose-module.sh "$choose_literal_input"
    assert_choose_literal \
        "choose: $literal_case stays literal through awk" \
        "$choose_literal_output" "$literal_case"
done

choose_seed_bin="$STATE_DIR/choose-seed-bin"
make_choose_seed_fixture "$choose_seed_bin"

choose_ascii_input="$STATE_DIR/choose-boundary-ascii.in"
choose_ascii_output="$STATE_DIR/choose-boundary-ascii.out"
write_boundary_events "$choose_ascii_input" choose-ascii 1
module_out_file_with_path "$choose_ascii_output" \
    modules/choose-module choose-module.sh "$choose_ascii_input" "$choose_seed_bin"
assert_bounded_actions "choose: ASCII output respects TNT's 1023-byte limit" \
    "$choose_ascii_output" choose-ascii 1

choose_utf8_input="$STATE_DIR/choose-boundary-utf8.in"
choose_utf8_output="$STATE_DIR/choose-boundary-utf8.out"
write_boundary_events "$choose_utf8_input" choose-utf8 1
module_out_file_with_path "$choose_utf8_output" \
    modules/choose-module choose-module.sh "$choose_utf8_input" "$choose_seed_bin"
assert_bounded_actions "choose: UTF-8 output is truncated only at code-point boundaries" \
    "$choose_utf8_output" choose-utf8 1

# --- quote-module ---
assert_handshakes quote modules/quote-module quote-module.sh quote-module
assert_command_event quote modules/quote-module quote-module.sh \
    "$(event erin /quote)" \
    '^\{"type":"message\.create","plain_text":"❝ .+ ❞"\}$'
assert_noop_event quote modules/quote-module quote-module.sh \
    "$(event other plain)" normal-message
assert_noop_event quote modules/quote-module quote-module.sh \
    "$(event other /quotes)" command-boundary
assert_noop_event quote modules/quote-module quote-module.sh \
    '{"type":"presence.updated","metadata":{"type":"message.created"},"message":{"sender":"other","plain_text":"/quote"}}' unknown-event

# --- examples/echo-module ---
assert_handshakes echo examples/echo-module echo-module.sh echo-module
assert_command_event echo examples/echo-module echo-module.sh \
    "$(event frank hello)" \
    '^\{"type":"message\.create","plain_text":"echo: hello"\}$'

echo_escaped_file="$STATE_DIR/echo-escaped.out"
module_out "$echo_escaped_file" examples/echo-module echo-module.sh \
    '{"type":"message.created","message":{"sender":"frank","plain_text":"say \\\"hi\\\" at C:\\\\tmp"}}'
assert_json_lines "echo: escaped quotes and backslashes survive parsing" \
    "$echo_escaped_file" \
    '^\{"type":"message\.create","plain_text":"echo: say \\\\\\\"hi\\\\\\\" at C:\\\\\\\\tmp"\}$' "$EVENT_OK"

echo_ascii_input="$STATE_DIR/echo-boundary-ascii.in"
echo_ascii_output="$STATE_DIR/echo-boundary-ascii.out"
write_boundary_events "$echo_ascii_input" echo-ascii 1
module_out_file "$echo_ascii_output" \
    examples/echo-module echo-module.sh "$echo_ascii_input"
assert_bounded_actions "echo: ASCII output respects TNT's 1023-byte limit" \
    "$echo_ascii_output" echo-ascii 1

echo_utf8_input="$STATE_DIR/echo-boundary-utf8.in"
echo_utf8_output="$STATE_DIR/echo-boundary-utf8.out"
write_boundary_events "$echo_utf8_input" echo-utf8 1
module_out_file "$echo_utf8_output" \
    examples/echo-module echo-module.sh "$echo_utf8_input"
assert_bounded_actions "echo: UTF-8 output is truncated only at code-point boundaries" \
    "$echo_utf8_output" echo-utf8 1

assert_noop_event echo examples/echo-module echo-module.sh \
    '{"type":"presence.updated","metadata":{"type":"message.created"},"message":{"sender":"mallory","plain_text":"spoofed"}}' unknown-event
assert_noop_event echo examples/echo-module echo-module.sh \
    '{"type":"message.created","message":{"sender":"frank","plain_text":"unsafe\u0001text"}}' escaped-control
assert_noop_event echo examples/echo-module echo-module.sh \
    '{"type":"message.created","message":{"sender":"frank","plain_text":"unsafe\ntext"}}' escaped-newline

echo_bad_event_file="$STATE_DIR/echo-missing-plain-text.out"
module_out "$echo_bad_event_file" examples/echo-module echo-module.sh \
    '{"type":"message.created","message":{"sender":"frank"}}'
assert_json_lines "echo: missing plain_text is only a no-op" \
    "$echo_bad_event_file" "$EVENT_OK"

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
