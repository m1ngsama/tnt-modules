#!/bin/sh
# Regression tests for scripts/check_modules.sh.

set -eu

PASS=0
FAIL=0
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
STATE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/tnt-modules-test.XXXXXX")
CHECKER="$ROOT/scripts/check_modules.sh"
PYTHON3=${TNT_MODULES_PYTHON:-python3}
CONFIGURED_CHECKER=${TNT_MODULE_CHECKER:-}

# Regression cases below exercise the built-in validator. Preserve an inherited
# checker so it can also be run against the repository after those cases.
TNT_MODULE_CHECKER=
export TNT_MODULE_CHECKER

cleanup() {
    rm -rf "$STATE_DIR"
}
trap cleanup EXIT INT TERM

pass() {
    echo "PASS $1"
    PASS=$((PASS + 1))
}

fail_case() {
    echo "FAIL $1"
    [ -z "${2:-}" ] || printf '%s\n' "$2"
    FAIL=$((FAIL + 1))
}

expect_pass() {
    label=$1
    shift
    if "$@" >"$STATE_DIR/stdout" 2>"$STATE_DIR/stderr"; then
        pass "$label"
    else
        output=$(cat "$STATE_DIR/stderr")
        fail_case "$label" "$output"
    fi
}

expect_fail() {
    label=$1
    shift
    if "$@" >"$STATE_DIR/stdout" 2>"$STATE_DIR/stderr"; then
        output=$(cat "$STATE_DIR/stdout")
        fail_case "$label" "$output"
    else
        pass "$label"
    fi
}

expect_status() {
    label=$1
    expected=$2
    shift 2
    if "$@" >"$STATE_DIR/stdout" 2>"$STATE_DIR/stderr"; then
        actual=0
    else
        actual=$?
    fi
    if [ "$actual" -eq "$expected" ]; then
        pass "$label"
    else
        output=$(cat "$STATE_DIR/stderr")
        fail_case "$label (expected status $expected, got $actual)" "$output"
    fi
}

run_with_timeout() {
    timeout_seconds=$1
    shift
    "$PYTHON3" - "$timeout_seconds" "$@" <<'PY'
import subprocess
import sys

timeout = float(sys.argv[1])
completed = subprocess.run(sys.argv[2:], timeout=timeout, check=False)
raise SystemExit(completed.returncode)
PY
}

checker_cleans_descendant() {
    module_dir=$1
    "$CHECKER" "$module_dir" >/dev/null 2>&1 || return 1
    [ -s "$module_dir/descendant.pid" ] || return 1
    "$PYTHON3" - "$module_dir/descendant.pid" <<'PY'
import os
import pathlib
import sys
import time

pid = int(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
for _ in range(40):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        raise SystemExit(0)
    time.sleep(0.05)
try:
    os.kill(pid, 9)
except ProcessLookupError:
    pass
raise SystemExit(f"module descendant {pid} survived checker cleanup")
PY
}

checker_interrupt_cleans_group() {
    module_dir=$1
    "$PYTHON3" - "$CHECKER" "$module_dir" <<'PY'
import os
import pathlib
import signal
import subprocess
import sys
import time

checker, module_dir_raw = sys.argv[1:]
module_dir = pathlib.Path(module_dir_raw)
module_pid_path = module_dir / "module.pid"
descendant_pid_path = module_dir / "descendant.pid"
ready_path = module_dir / "ready"


def group_exists(process_group):
    try:
        os.killpg(process_group, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


module_pid = None
process = subprocess.Popen(
    [checker, str(module_dir)],
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
)
try:
    ready_deadline = time.monotonic() + 3.0
    while not ready_path.exists() and time.monotonic() < ready_deadline:
        if process.poll() is not None:
            raise SystemExit(
                f"checker exited before interrupt fixture was ready: {process.returncode}"
            )
        time.sleep(0.01)
    if not ready_path.exists():
        raise SystemExit("interrupt fixture did not become ready")

    module_pid = int(module_pid_path.read_text(encoding="utf-8"))
    descendant_pid = int(descendant_pid_path.read_text(encoding="utf-8"))
    process.send_signal(signal.SIGTERM)
    try:
        returncode = process.wait(timeout=3.0)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()
        raise SystemExit("checker did not exit after SIGTERM")
    if returncode == 0:
        raise SystemExit("interrupted checker unexpectedly succeeded")

    cleanup_deadline = time.monotonic() + 3.0
    while group_exists(module_pid) and time.monotonic() < cleanup_deadline:
        time.sleep(0.01)
    if group_exists(module_pid):
        raise SystemExit(
            "interrupted checker left module process group alive: "
            f"leader={module_pid}, descendant={descendant_pid}"
        )
finally:
    if process.poll() is None:
        process.kill()
        process.wait()
    if module_pid is not None and group_exists(module_pid):
        try:
            os.killpg(module_pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
PY
}

write_module() {
    dir=$1
    name=$2
    min_version=${3:-1.1.0}
    module_version=${4:-0.1.0}
    mkdir -p "$dir"
    cat >"$dir/tnt-module.json" <<JSON
{
  "protocol": "tnt.module.v1",
  "name": "$name",
  "version": "$module_version",
  "tnt_min_version": "$min_version",
  "entrypoint": "./module.sh",
  "permissions": ["message:read", "message:create"],
  "events": ["message.created"]
}
JSON
    cat >"$dir/module.sh" <<SH
#!/bin/sh
while IFS= read -r line; do
  if printf '%s\n' "\$line" | grep -q '"type"[[:space:]]*:[[:space:]]*"handshake"'; then
    printf '%s\n' '{"type":"handshake.ok","protocol":"tnt.module.v1","module":{"name":"$name","version":"$module_version"}}'
  else
    printf '%s\n' '{"type":"event.ok"}'
  fi
done
SH
    chmod +x "$dir/module.sh"
}

set_manifest_field() {
    manifest=$1
    key=$2
    json_value=$3
    "$PYTHON3" - "$manifest" "$key" "$json_value" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
document = json.loads(path.read_text(encoding="utf-8"))
document[sys.argv[2]] = json.loads(sys.argv[3])
path.write_text(json.dumps(document, indent=2) + "\n", encoding="utf-8")
PY
}

delete_manifest_field() {
    manifest=$1
    key=$2
    "$PYTHON3" - "$manifest" "$key" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
document = json.loads(path.read_text(encoding="utf-8"))
document.pop(sys.argv[2], None)
path.write_text(json.dumps(document, indent=2) + "\n", encoding="utf-8")
PY
}

write_handshake_response() {
    dir=$1
    response=$2
    printf '%s\n' "$response" >"$dir/handshake-response.txt"
    cat >"$dir/module.sh" <<'SH'
#!/bin/sh
while IFS= read -r line; do
  sed -n '1p' ./handshake-response.txt
done
SH
    chmod +x "$dir/module.sh"
}

pad_file_to_size() {
    file=$1
    target_size=$2
    "$PYTHON3" - "$file" "$target_size" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
target = int(sys.argv[2])
content = path.read_bytes().rstrip()
if len(content) > target:
    raise SystemExit(f"fixture is already larger than {target} bytes")
path.write_bytes(content + b" " * (target - len(content)))
PY
}

pad_jsonl_payload_to_size() {
    file=$1
    target_size=$2
    "$PYTHON3" - "$file" "$target_size" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
target = int(sys.argv[2])
content = path.read_bytes()
if not content.endswith(b"\n"):
    raise SystemExit("JSONL fixture is not newline terminated")
payload = content[:-1]
if len(payload) > target:
    raise SystemExit(f"fixture payload is already larger than {target} bytes")
path.write_bytes(payload + b" " * (target - len(payload)) + b"\n")
PY
}

assert_benchmark_invocation() {
    log=$1
    python_log=$2
    shift 2
    "$PYTHON3" - "$log" "$python_log" "$@" <<'PY'
import json
import pathlib
import sys

log_path = pathlib.Path(sys.argv[1])
python_log_path = pathlib.Path(sys.argv[2])
expected_paths = sys.argv[3:]
records = [
    json.loads(line)
    for line in log_path.read_text(encoding="utf-8").splitlines()
]
expected = ["--check", "--idle-resources"]
for path in expected_paths:
    expected.extend(["--module-dir", path])
if records != [expected]:
    raise SystemExit(
        f"unexpected benchmark invocations: expected {[expected]!r}, got {records!r}"
    )
python_calls = python_log_path.read_text(encoding="utf-8").splitlines()
if python_calls != ["python"]:
    raise SystemExit(
        f"configured Python was not called exactly once: {python_calls!r}"
    )
PY
}

assert_default_benchmark_invocation() {
    log=$1
    python_log=$2
    "$PYTHON3" - "$log" "$python_log" "$ROOT" <<'PY'
import json
import pathlib
import sys

log_path = pathlib.Path(sys.argv[1])
python_log_path = pathlib.Path(sys.argv[2])
root = pathlib.Path(sys.argv[3])
expected_paths = []
for base_name in ("examples", "modules"):
    base = root / base_name
    if base.is_dir():
        expected_paths.extend(
            str(path) for path in sorted(path for path in base.iterdir() if path.is_dir())
        )
expected = ["--check", "--idle-resources"]
for path in expected_paths:
    expected.extend(["--module-dir", path])
records = [
    json.loads(line)
    for line in log_path.read_text(encoding="utf-8").splitlines()
]
if records != [expected]:
    raise SystemExit(
        f"default directories were not forwarded exactly once: "
        f"expected {[expected]!r}, got {records!r}"
    )
python_calls = python_log_path.read_text(encoding="utf-8").splitlines()
if python_calls != ["python"]:
    raise SystemExit(
        f"configured Python was not called exactly once: {python_calls!r}"
    )
PY
}

assert_validation_precedes_benchmark() {
    sequence_log=$1
    shift
    "$PYTHON3" - "$sequence_log" "$@" <<'PY'
import pathlib
import sys

sequence_path = pathlib.Path(sys.argv[1])
expected = [f"checker\t{path}" for path in sys.argv[2:]] + ["benchmark"]
actual = sequence_path.read_text(encoding="utf-8").splitlines()
if actual != expected:
    raise SystemExit(
        f"benchmark did not follow every delegated check: "
        f"expected {expected!r}, got {actual!r}"
    )
PY
}

echo "=== TNT Modules Check Tests ==="

expect_pass "all repository modules pass built-in validation" \
    "$CHECKER" --tnt-version 1.1.0

valid_dir="$STATE_DIR/valid"
write_module "$valid_dir" "valid-module"
expect_pass "valid module passes" \
    "$CHECKER" --tnt-version 1.1.0 "$valid_dir"

space_dir="$STATE_DIR/path with spaces"
write_module "$space_dir" "space-path-module"
expect_pass "module directory path may contain spaces" "$CHECKER" "$space_dir"

plain_entry_dir="$STATE_DIR/plain-entry"
write_module "$plain_entry_dir" "plain-entry"
set_manifest_field "$plain_entry_dir/tnt-module.json" entrypoint '"module.sh"'
expect_pass "relative entrypoint without slash passes" "$CHECKER" "$plain_entry_dir"

compatible_dir="$STATE_DIR/compatible"
write_module "$compatible_dir" "compatible-module" "v1.0.1"
expect_pass "compatible v-prefixed TNT minimum version passes" \
    "$CHECKER" --tnt-version v1.1.0 "$compatible_dir"

future_dir="$STATE_DIR/future"
write_module "$future_dir" "future-module" "9.0.0"
expect_fail "future TNT minimum version is rejected" \
    "$CHECKER" --tnt-version 1.1.0 "$future_dir"

malformed_min_dir="$STATE_DIR/malformed-min"
write_module "$malformed_min_dir" "malformed-min"
set_manifest_field "$malformed_min_dir/tnt-module.json" tnt_min_version '"1..0"'
expect_fail "malformed TNT minimum version is rejected" \
    "$CHECKER" --tnt-version 2.0.0 "$malformed_min_dir"

expect_fail "malformed target TNT version is rejected" \
    "$CHECKER" --tnt-version 2..0 "$valid_dir"
expect_fail "incomplete target TNT version is rejected" \
    "$CHECKER" --tnt-version 2.0 "$valid_dir"

bad_name_dir="$STATE_DIR/bad-name"
write_module "$bad_name_dir" "Bad_Name"
expect_fail "invalid module name is rejected" "$CHECKER" "$bad_name_dir"

long_name_dir="$STATE_DIR/long-name"
long_name=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
write_module "$long_name_dir" "$long_name"
expect_fail "module name longer than 56 bytes is rejected" \
    "$CHECKER" "$long_name_dir"

unsafe_entry_dir="$STATE_DIR/unsafe-entry"
write_module "$unsafe_entry_dir" "unsafe-entry"
set_manifest_field "$unsafe_entry_dir/tnt-module.json" entrypoint '"../module.sh"'
expect_fail "unsafe entrypoint is rejected" "$CHECKER" "$unsafe_entry_dir"

missing_version_dir="$STATE_DIR/missing-version"
write_module "$missing_version_dir" "missing-version"
delete_manifest_field "$missing_version_dir/tnt-module.json" version
expect_fail "missing required manifest version is rejected" \
    "$CHECKER" "$missing_version_dir"

wrong_type_dir="$STATE_DIR/wrong-type"
write_module "$wrong_type_dir" "wrong-type"
set_manifest_field "$wrong_type_dir/tnt-module.json" version 1
expect_fail "non-string manifest version is rejected" \
    "$CHECKER" "$wrong_type_dir"

for bad_module_version in banana 1.0 v1.0.0; do
    bad_version_label=$(printf '%s' "$bad_module_version" | tr '.' '-')
    bad_version_dir="$STATE_DIR/bad-module-version-$bad_version_label"
    write_module "$bad_version_dir" "bad-version-$bad_version_label" \
        1.1.0 "$bad_module_version"
    expect_fail "malformed module version $bad_module_version is rejected" \
        "$CHECKER" "$bad_version_dir"
done

array_type_dir="$STATE_DIR/array-type"
write_module "$array_type_dir" "array-type"
set_manifest_field "$array_type_dir/tnt-module.json" permissions '"message:read message:create"'
expect_fail "permissions must be an array" "$CHECKER" "$array_type_dir"

array_member_dir="$STATE_DIR/array-member"
write_module "$array_member_dir" "array-member"
set_manifest_field "$array_member_dir/tnt-module.json" events '["message.created", 1]'
expect_fail "event array members must be strings" \
    "$CHECKER" "$array_member_dir"

decoy_dir="$STATE_DIR/decoy-capabilities"
write_module "$decoy_dir" "decoy-capabilities"
set_manifest_field "$decoy_dir/tnt-module.json" permissions '[]'
set_manifest_field "$decoy_dir/tnt-module.json" events '[]'
set_manifest_field "$decoy_dir/tnt-module.json" description \
    '"message:read message:create message.created"'
expect_fail "capability strings outside their arrays do not satisfy requirements" \
    "$CHECKER" "$decoy_dir"

duplicate_member_dir="$STATE_DIR/duplicate-member"
write_module "$duplicate_member_dir" "duplicate-member"
set_manifest_field "$duplicate_member_dir/tnt-module.json" permissions \
    '["message:read", "message:create", "message:create"]'
expect_fail "duplicate capability members are rejected" \
    "$CHECKER" "$duplicate_member_dir"

malformed_json_dir="$STATE_DIR/malformed-json"
write_module "$malformed_json_dir" "malformed-json"
printf '%s\n' '{"protocol":"tnt.module.v1"' \
    >"$malformed_json_dir/tnt-module.json"
expect_fail "syntactically invalid JSON manifest is rejected" \
    "$CHECKER" "$malformed_json_dir"

duplicate_key_dir="$STATE_DIR/duplicate-key"
write_module "$duplicate_key_dir" "duplicate-key"
"$PYTHON3" - "$duplicate_key_dir/tnt-module.json" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
path.write_text(text.replace('{\n', '{\n  "protocol": "tnt.module.v1",\n', 1),
                encoding="utf-8")
PY
expect_fail "duplicate JSON object keys are rejected" \
    "$CHECKER" "$duplicate_key_dir"

root_array_dir="$STATE_DIR/root-array"
write_module "$root_array_dir" "root-array"
printf '%s\n' '[]' >"$root_array_dir/tnt-module.json"
expect_fail "manifest root must be an object" "$CHECKER" "$root_array_dir"

max_manifest_dir="$STATE_DIR/max-manifest"
write_module "$max_manifest_dir" "max-manifest"
pad_file_to_size "$max_manifest_dir/tnt-module.json" 4094
expect_pass "4094-byte manifest fits TNT's buffer" \
    "$CHECKER" "$max_manifest_dir"

oversized_manifest_dir="$STATE_DIR/oversized-manifest"
write_module "$oversized_manifest_dir" "oversized-manifest"
pad_file_to_size "$oversized_manifest_dir/tnt-module.json" 4095
expect_fail "4095-byte manifest is rejected like TNT core" \
    "$CHECKER" "$oversized_manifest_dir"

bad_handshake_dir="$STATE_DIR/bad-handshake"
write_module "$bad_handshake_dir" "bad-handshake"
write_handshake_response "$bad_handshake_dir" '{"type":"event.ok"}'
expect_fail "wrong handshake response type is rejected" \
    "$CHECKER" "$bad_handshake_dir"

non_json_handshake_dir="$STATE_DIR/non-json-handshake"
write_module "$non_json_handshake_dir" "non-json-handshake"
write_handshake_response "$non_json_handshake_dir" \
    'NOT-JSON {"type":"handshake.ok","protocol":"tnt.module.v1","module":{"name":"non-json-handshake","version":"0.1.0"}}'
expect_fail "handshake must be valid JSON" "$CHECKER" "$non_json_handshake_dir"

nested_type_dir="$STATE_DIR/nested-type"
write_module "$nested_type_dir" "nested-type"
write_handshake_response "$nested_type_dir" \
    '{"type":"event.ok","protocol":"tnt.module.v1","metadata":{"type":"handshake.ok"},"module":{"name":"nested-type","version":"0.1.0"}}'
expect_fail "nested handshake type cannot spoof the top-level type" \
    "$CHECKER" "$nested_type_dir"

wrong_handshake_name_dir="$STATE_DIR/wrong-handshake-name"
write_module "$wrong_handshake_name_dir" "expected-name"
write_handshake_response "$wrong_handshake_name_dir" \
    '{"type":"handshake.ok","protocol":"tnt.module.v1","module":{"name":"other-name","version":"0.1.0"}}'
expect_fail "handshake module name must match the manifest" \
    "$CHECKER" "$wrong_handshake_name_dir"

wrong_handshake_version_dir="$STATE_DIR/wrong-handshake-version"
write_module "$wrong_handshake_version_dir" "wrong-handshake-version"
write_handshake_response "$wrong_handshake_version_dir" \
    '{"type":"handshake.ok","protocol":"tnt.module.v1","module":{"name":"wrong-handshake-version","version":"9.9.9"}}'
expect_fail "handshake module version must match the manifest" \
    "$CHECKER" "$wrong_handshake_version_dir"

max_handshake_dir="$STATE_DIR/max-handshake"
write_module "$max_handshake_dir" "max-handshake"
write_handshake_response "$max_handshake_dir" \
    '{"type":"handshake.ok","protocol":"tnt.module.v1","module":{"name":"max-handshake","version":"0.1.0"}}'
pad_jsonl_payload_to_size "$max_handshake_dir/handshake-response.txt" 4094
expect_pass "4094-byte handshake payload fits TNT's JSONL buffer" \
    "$CHECKER" "$max_handshake_dir"

oversized_handshake_dir="$STATE_DIR/oversized-handshake"
write_module "$oversized_handshake_dir" "oversized-handshake"
write_handshake_response "$oversized_handshake_dir" \
    '{"type":"handshake.ok","protocol":"tnt.module.v1","module":{"name":"oversized-handshake","version":"0.1.0"}}'
pad_jsonl_payload_to_size \
    "$oversized_handshake_dir/handshake-response.txt" 4095
expect_fail "4095-byte handshake payload cannot fit as complete JSONL" \
    "$CHECKER" "$oversized_handshake_dir"

silent_dir="$STATE_DIR/silent"
write_module "$silent_dir" "silent-module"
cat >"$silent_dir/module.sh" <<'SH'
#!/bin/sh
exit 0
SH
chmod +x "$silent_dir/module.sh"
expect_fail "silent module is rejected" "$CHECKER" "$silent_dir"

one_shot_dir="$STATE_DIR/one-shot"
write_module "$one_shot_dir" "one-shot-module"
cat >"$one_shot_dir/module.sh" <<'SH'
#!/bin/sh
IFS= read -r line || exit 0
printf '%s\n' '{"type":"handshake.ok","protocol":"tnt.module.v1","module":{"name":"one-shot-module","version":"0.1.0"}}'
exit 0
SH
chmod +x "$one_shot_dir/module.sh"
expect_fail "entrypoint that exits after handshake is rejected" \
    "$CHECKER" "$one_shot_dir"

unterminated_dir="$STATE_DIR/unterminated"
write_module "$unterminated_dir" "unterminated"
cat >"$unterminated_dir/module.sh" <<'SH'
#!/bin/sh
IFS= read -r line || exit 0
printf '%s' '{"type":"handshake.ok","protocol":"tnt.module.v1","module":{"name":"unterminated","version":"0.1.0"}}'
SH
chmod +x "$unterminated_dir/module.sh"
expect_fail "handshake JSONL response must end with a newline" \
    "$CHECKER" "$unterminated_dir"

extra_output_dir="$STATE_DIR/extra-handshake-output"
write_module "$extra_output_dir" "extra-handshake-output"
cat >"$extra_output_dir/module.sh" <<'SH'
#!/bin/sh
IFS= read -r line || exit 0
printf '%s\n' '{"type":"handshake.ok","protocol":"tnt.module.v1","module":{"name":"extra-handshake-output","version":"0.1.0"}}'
printf '%s\n' '{"type":"event.ok"}'
SH
chmod +x "$extra_output_dir/module.sh"
expect_fail "unsolicited output after handshake.ok is rejected" \
    "$CHECKER" "$extra_output_dir"

delayed_output_dir="$STATE_DIR/delayed-handshake-output"
write_module "$delayed_output_dir" "delayed-handshake-output"
cat >"$delayed_output_dir/module.sh" <<'SH'
#!/bin/sh
IFS= read -r line || exit 0
printf '%s\n' '{"type":"handshake.ok","protocol":"tnt.module.v1","module":{"name":"delayed-handshake-output","version":"0.1.0"}}'
sleep 0.1
printf '%s\n' '{"type":"event.ok"}'
SH
chmod +x "$delayed_output_dir/module.sh"
expect_fail "shortly delayed unsolicited handshake output is rejected" \
    "$CHECKER" "$delayed_output_dir"

stubborn_dir="$STATE_DIR/stubborn"
write_module "$stubborn_dir" "stubborn-module"
cat >"$stubborn_dir/module.sh" <<'SH'
#!/bin/sh
trap '' TERM
while IFS= read -r line; do
  printf '%s\n' '{"type":"handshake.ok","protocol":"tnt.module.v1","module":{"name":"stubborn-module","version":"0.1.0"}}'
done
SH
chmod +x "$stubborn_dir/module.sh"
expect_pass "checker cleanup cannot be blocked by ignored SIGTERM" \
    run_with_timeout 3 "$CHECKER" "$stubborn_dir"

descendant_dir="$STATE_DIR/descendant-module"
write_module "$descendant_dir" "descendant-module"
cat >"$descendant_dir/module.sh" <<'SH'
#!/bin/sh
while IFS= read -r line; do
  (
    trap '' TERM
    while :; do sleep 10; done
  ) &
  printf '%s\n' "$!" >./descendant.pid
  printf '%s\n' '{"type":"handshake.ok","protocol":"tnt.module.v1","module":{"name":"descendant-module","version":"0.1.0"}}'
done
SH
chmod +x "$descendant_dir/module.sh"
expect_pass "checker cleanup terminates module descendants" \
    checker_cleans_descendant "$descendant_dir"

interrupt_dir="$STATE_DIR/interrupted-checker"
write_module "$interrupt_dir" "interrupted-checker"
cat >"$interrupt_dir/module.sh" <<'SH'
#!/bin/sh
printf '%s\n' "$$" >./module.pid
(
  trap '' TERM
  while :; do sleep 10; done
) &
printf '%s\n' "$!" >./descendant.pid
printf '%s\n' ready >./ready
trap '' TERM
while :; do sleep 10; done
SH
chmod +x "$interrupt_dir/module.sh"
expect_pass "interrupted checker terminates the module process group" \
    checker_interrupt_cleans_group "$interrupt_dir"

fake_checker="$STATE_DIR/fake-checker.sh"
cat >"$fake_checker" <<'SH'
#!/bin/sh
while [ "$#" -gt 0 ]; do
  case "$1" in
    --tnt-version)
      [ "$2" = "1.1.0" ] || exit 1
      shift 2
      ;;
    *)
      module_dir=$1
      shift
      ;;
  esac
done
[ -f "$module_dir/tnt-module.json" ] || exit 1
if [ -n "${FAKE_SEQUENCE_LOG:-}" ]; then
  printf 'checker\t%s\n' "$module_dir" >>"$FAKE_SEQUENCE_LOG"
fi
SH
chmod +x "$fake_checker"
expect_pass "external TNT checker can be delegated without Python" \
    env TNT_MODULES_PYTHON="$STATE_DIR/does-not-exist" \
    TNT_MODULES_BENCHMARK="$STATE_DIR/also-not-used.py" \
    "$CHECKER" --tnt-version 1.1.0 --checker "$fake_checker" "$valid_dir"

fake_benchmark="$STATE_DIR/fake benchmark.py"
cat >"$fake_benchmark" <<'PY'
import json
import os
import pathlib
import sys

with pathlib.Path(os.environ["FAKE_BENCHMARK_LOG"]).open(
    "a", encoding="utf-8"
) as stream:
    print(json.dumps(sys.argv[1:]), file=stream)
sequence_log = os.environ.get("FAKE_SEQUENCE_LOG")
if sequence_log:
    with pathlib.Path(sequence_log).open("a", encoding="utf-8") as stream:
        print("benchmark", file=stream)
raise SystemExit(int(os.environ.get("FAKE_BENCHMARK_EXIT", "0")))
PY

fake_python="$STATE_DIR/fake-python.sh"
cat >"$fake_python" <<'SH'
#!/bin/sh
printf '%s\n' python >>"$FAKE_PYTHON_LOG"
exec "$REAL_PYTHON3" "$@"
SH
chmod +x "$fake_python"

benchmark_log="$STATE_DIR/benchmark-invocations.jsonl"
python_log="$STATE_DIR/python-invocations.txt"
sequence_log="$STATE_DIR/performance-sequence.txt"
: >"$benchmark_log"
: >"$python_log"
: >"$sequence_log"
expect_pass "external checks precede one configured full performance profile" \
    env TNT_MODULES_PYTHON="$fake_python" \
    TNT_MODULES_BENCHMARK="$fake_benchmark" \
    REAL_PYTHON3="$PYTHON3" \
    FAKE_PYTHON_LOG="$python_log" \
    FAKE_BENCHMARK_LOG="$benchmark_log" \
    FAKE_SEQUENCE_LOG="$sequence_log" \
    "$CHECKER" --tnt-version 1.1.0 --checker "$fake_checker" --performance \
    "$valid_dir" "$space_dir"
expect_pass "performance argv preserves flags and module paths with spaces" \
    assert_benchmark_invocation "$benchmark_log" "$python_log" \
    "$valid_dir" "$space_dir"
expect_pass "performance starts only after all delegated checks finish" \
    assert_validation_precedes_benchmark "$sequence_log" \
    "$valid_dir" "$space_dir"

: >"$benchmark_log"
: >"$python_log"
expect_pass "performance profile forwards all default examples and modules" \
    env TNT_MODULES_PYTHON="$fake_python" \
    TNT_MODULES_BENCHMARK="$fake_benchmark" \
    REAL_PYTHON3="$PYTHON3" \
    FAKE_PYTHON_LOG="$python_log" \
    FAKE_BENCHMARK_LOG="$benchmark_log" \
    "$CHECKER" --tnt-version 1.1.0 --checker "$fake_checker" --performance
expect_pass "default performance benchmark is invoked exactly once" \
    assert_default_benchmark_invocation "$benchmark_log" "$python_log"

: >"$benchmark_log"
: >"$python_log"
expect_status "performance benchmark exit status is propagated" 7 \
    env TNT_MODULES_PYTHON="$fake_python" \
    TNT_MODULES_BENCHMARK="$fake_benchmark" \
    REAL_PYTHON3="$PYTHON3" \
    FAKE_PYTHON_LOG="$python_log" \
    FAKE_BENCHMARK_LOG="$benchmark_log" \
    FAKE_BENCHMARK_EXIT=7 \
    "$CHECKER" --tnt-version 1.1.0 --checker "$fake_checker" \
    --performance "$valid_dir"
expect_pass "failing performance benchmark still runs exactly once" \
    assert_benchmark_invocation "$benchmark_log" "$python_log" "$valid_dir"

expect_fail "performance profile rejects a missing configured benchmark" \
    env TNT_MODULES_BENCHMARK="$STATE_DIR/does-not-exist.py" \
    "$CHECKER" --tnt-version 1.1.0 --checker "$fake_checker" \
    --performance "$valid_dir"

if [ -n "$CONFIGURED_CHECKER" ]; then
    expect_pass "configured external TNT checker accepts repository modules" \
        "$CHECKER" --checker "$CONFIGURED_CHECKER" --tnt-version 1.1.0
fi

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
