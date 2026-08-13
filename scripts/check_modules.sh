#!/bin/sh
# Validate TNT module directories in this repository.

set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TNT_VERSION=${TNT_MODULES_TNT_VERSION:-1.1.0}
CHECKER=${TNT_MODULE_CHECKER:-}
PYTHON3=${TNT_MODULES_PYTHON:-python3}
BENCHMARK=${TNT_MODULES_BENCHMARK:-$ROOT/scripts/benchmark_modules.py}
PERFORMANCE=0

usage() {
    cat <<'USAGE'
Usage: scripts/check_modules.sh [--tnt-version VERSION] [--checker FILE]
                                [--performance] [MODULE_DIR ...]

With no MODULE_DIR arguments, validates module directories under examples/ and
modules/. If --checker or TNT_MODULE_CHECKER points to TNT's module_check.sh,
that checker is used. Otherwise this script runs the repository's built-in
manifest and handshake checks. --performance additionally runs the repository
benchmark once for all validated directories, enforcing latency, output, and
eight-slot idle resource budgets.
USAGE
}

fail() {
    echo "check-modules: $*" >&2
    exit 1
}

normalize_version() {
    version=${1#v}
    major=${version%%.*}
    rest=${version#*.}
    [ "$rest" != "$version" ] || return 1
    minor=${rest%%.*}
    patch=${rest#*.}
    [ "$patch" != "$rest" ] || return 1

    case "$major:$minor:$patch" in
        *[!0-9:]*|:*|*::*|*:|*.*)
            return 1
            ;;
    esac
    printf '%s.%s.%s\n' "$major" "$minor" "$patch"
}

list_default_modules() {
    for base in "$ROOT/examples" "$ROOT/modules"; do
        [ -d "$base" ] || continue
        find "$base" -mindepth 1 -maxdepth 1 -type d | sort
    done
}

handshake_line_ready() {
    "$PYTHON3" -c \
        'import sys
with open(sys.argv[1], "rb") as stream:
    prefix = stream.read(4096)
raise SystemExit(0 if b"\n" in prefix or len(prefix) >= 4096 else 1)' \
        "$1"
}

validate_handshake() {
    response_file=$1
    manifest=$2

    "$PYTHON3" - "$response_file" "$manifest" <<'PY'
import json
import sys

response_path, manifest_path = sys.argv[1:]


def abort(message):
    print(f"check-modules: invalid handshake from {response_path}: {message}",
          file=sys.stderr)
    raise SystemExit(1)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate object key: {key}")
        result[key] = value
    return result


def reject_constant(value):
    raise ValueError(f"non-JSON numeric constant: {value}")


def loads_strict(text):
    return json.loads(text, object_pairs_hook=unique_object,
                      parse_constant=reject_constant)


try:
    with open(response_path, "rb") as response_stream:
        # A complete JSONL record must fit in TNT's 4096-byte line buffer:
        # at most 4094 payload bytes, one newline, and one C terminator.
        # Read past that valid record size so both overflow and unsolicited
        # output after handshake.ok are rejected.
        raw_output = response_stream.read(4097)
    newline = raw_output.find(b"\n")
    raw_line = raw_output if newline < 0 else raw_output[:newline + 1]
    if not raw_line:
        abort("empty response")
    if not raw_line.endswith(b"\n"):
        abort("response is not newline-terminated JSONL")
    if len(raw_line) > 4095:
        abort("response exceeds TNT's 4094-byte handshake payload limit")
    if len(raw_output) != len(raw_line):
        abort("unexpected output after handshake response")
    response = loads_strict(raw_line.decode("utf-8"))

    with open(manifest_path, "rb") as manifest_stream:
        raw_manifest = manifest_stream.read(4095)
    if len(raw_manifest) >= 4095:
        abort("manifest exceeds TNT's 4094-byte limit")
    manifest = loads_strict(raw_manifest.decode("utf-8"))
except (OSError, UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
    abort(str(exc))

if type(response) is not dict:
    abort("response must be a JSON object")
if response.get("type") != "handshake.ok":
    abort('top-level "type" must be "handshake.ok"')
if response.get("protocol") != "tnt.module.v1":
    abort('top-level "protocol" must be "tnt.module.v1"')

module = response.get("module")
if type(module) is not dict:
    abort('"module" must be an object')
if module.get("name") != manifest["name"]:
    abort('module name does not match manifest "name"')
if module.get("version") != manifest["version"]:
    abort('module version does not match manifest "version"')
PY
}

run_handshake_check() {
    module_dir=$1
    entrypoint=$2
    manifest=$3

    tmpdir=
    in_pipe=
    out_file=
    err_file=
    module_pid=
    input_open=0
    cleanup_done=0

    stop_module_group() {
        process_pid=$1
        [ -n "$process_pid" ] || return 0
        # The Python launcher makes its PID the process-group ID before exec.
        # Kill the group so helpers forked by a module cannot outlive validation.
        "$PYTHON3" - "$process_pid" <<'PY' || true
import os
import signal
import sys

process_group = int(sys.argv[1])
for signum in (signal.SIGTERM, signal.SIGKILL):
    try:
        os.killpg(process_group, signum)
    except ProcessLookupError:
        # Cleanup may race the launcher's os.setsid(). Until the new process
        # group exists, signal the launcher PID directly instead of waiting on
        # a process that the checker otherwise cannot stop.
        try:
            os.kill(process_group, signum)
        except ProcessLookupError:
            break
PY
        wait "$process_pid" 2>/dev/null || true
    }

    cleanup_handshake() {
        [ "$cleanup_done" -eq 0 ] || return 0
        cleanup_done=1
        if [ "$input_open" -eq 1 ]; then
            exec 9>&-
            input_open=0
        fi
        stop_module_group "$module_pid"
        [ -z "$tmpdir" ] || rm -rf "$tmpdir"
    }

    # A signal can arrive while the checker is polling or validating. Always
    # close the retained FIFO writer and terminate the complete module process
    # group before leaving the script. cleanup_handshake is deliberately
    # idempotent because a signal trap is followed by the EXIT trap.
    trap cleanup_handshake EXIT
    trap 'cleanup_handshake; exit 1' HUP INT TERM

    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/tnt-modules-check.XXXXXX")
    in_pipe="$tmpdir/stdin"
    out_file="$tmpdir/stdout"
    err_file="$tmpdir/stderr"
    mkfifo "$in_pipe"
    case "$entrypoint" in
        */*) entry_run=$entrypoint ;;
        *) entry_run="./$entrypoint" ;;
    esac

    "$PYTHON3" -c \
        'import os, sys
module_dir, entrypoint = sys.argv[1:]
os.setsid()
os.chdir(module_dir)
os.execv(entrypoint, [entrypoint])' \
        "$module_dir" "$entry_run" \
        <"$in_pipe" >"$out_file" 2>"$err_file" &
    module_pid=$!

    # Keep the write side open until cleanup, matching TNT core's persistent
    # stdin pipe. Closing it after the handshake would make healthy read loops
    # exit on EOF and would incorrectly accept one-shot entrypoints.
    exec 9>"$in_pipe"
    input_open=1
    printf '%s\n' "{\"type\":\"handshake\",\"protocol\":\"tnt.module.v1\",\"server\":{\"name\":\"tnt\",\"version\":\"$TNT_VERSION\"}}" >&9

    i=0
    # This repository validator allows extra scheduling headroom beyond TNT's
    # runtime timeout so parallel CI load does not create false negatives.
    while [ "$i" -lt 50 ]; do
        if [ -s "$out_file" ] && handshake_line_ready "$out_file"; then
            break
        fi
        kill -0 "$module_pid" 2>/dev/null || break
        i=$((i + 1))
        sleep 0.1
    done

    # A module must remain silent after its one handshake record. This bounded
    # quiet window catches buffered and shortly delayed unsolicited startup
    # output without turning validation into an unbounded monitor.
    sleep 0.2

    status=0
    if ! kill -0 "$module_pid" 2>/dev/null; then
        echo "check-modules: entrypoint exited after handshake: $module_dir" >&2
        status=1
    else
        validate_handshake "$out_file" "$manifest" || status=$?
    fi
    cleanup_handshake
    trap - EXIT HUP INT TERM
    return "$status"
}

validate_manifest() {
    manifest=$1

    "$PYTHON3" - "$manifest" "$TNT_VERSION" <<'PY'
import json
import re
import sys

manifest_path, target_version = sys.argv[1:]


def abort(message):
    print(f"check-modules: invalid manifest {manifest_path}: {message}",
          file=sys.stderr)
    raise SystemExit(1)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate object key: {key}")
        result[key] = value
    return result


def reject_constant(value):
    raise ValueError(f"non-JSON numeric constant: {value}")


def required_string(document, key):
    if key not in document:
        abort(f'missing required field "{key}"')
    value = document[key]
    if type(value) is not str:
        abort(f'field "{key}" must be a string')
    if not value:
        abort(f'field "{key}" must not be empty')
    return value


def required_string_array(document, key):
    if key not in document:
        abort(f'missing required field "{key}"')
    values = document[key]
    if type(values) is not list:
        abort(f'field "{key}" must be an array')
    if any(type(value) is not str or not value for value in values):
        abort(f'field "{key}" must contain only non-empty strings')
    if len(values) != len(set(values)):
        abort(f'field "{key}" must not contain duplicate members')
    return values


def parse_tnt_version(value, field):
    normalized = value[1:] if value.startswith("v") else value
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", normalized):
        abort(f'field "{field}" must be a MAJOR.MINOR.PATCH version')
    return tuple(int(component) for component in normalized.split("."))


def validate_module_version(value):
    # Module manifests use the unprefixed SemVer core form. TNT target and
    # minimum versions retain their existing optional leading "v" support.
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", value):
        abort('field "version" must be an unprefixed MAJOR.MINOR.PATCH version')


try:
    # TNT reads at most sizeof(buffer) - 1 bytes and rejects a manifest when
    # that 4095-byte read fills the buffer. Mirror that exact byte boundary.
    with open(manifest_path, "rb") as manifest_stream:
        raw_manifest = manifest_stream.read(4095)
    if len(raw_manifest) >= 4095:
        abort("manifest exceeds TNT's 4094-byte limit")
    manifest = json.loads(raw_manifest.decode("utf-8"),
                          object_pairs_hook=unique_object,
                          parse_constant=reject_constant)
except (OSError, UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
    abort(str(exc))

if type(manifest) is not dict:
    abort("manifest root must be a JSON object")

protocol = required_string(manifest, "protocol")
name = required_string(manifest, "name")
version = required_string(manifest, "version")
entrypoint = required_string(manifest, "entrypoint")
permissions = required_string_array(manifest, "permissions")
events = required_string_array(manifest, "events")

validate_module_version(version)

if protocol != "tnt.module.v1":
    abort(f'unsupported protocol: {protocol}')
if not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]*[a-z0-9])?", name) or len(name) > 56:
    abort(f'invalid module name: {name}')
if any(ord(character) < 32 or ord(character) == 127 or
       character.isspace() or character in '|;&`$<>\\'
       for character in entrypoint) or entrypoint.startswith("/") or ".." in entrypoint:
    abort(f'unsafe entrypoint: {entrypoint}')
if "message:read" not in permissions:
    abort('missing "message:read" member in "permissions"')
if "message:create" not in permissions:
    abort('missing "message:create" member in "permissions"')
if "message.created" not in events:
    abort('missing "message.created" member in "events"')

if "description" in manifest and type(manifest["description"]) is not str:
    abort('field "description" must be a string when present')

target = parse_tnt_version(target_version, "target TNT version")
if "tnt_min_version" in manifest:
    minimum_value = manifest["tnt_min_version"]
    if type(minimum_value) is not str or not minimum_value:
        abort('field "tnt_min_version" must be a non-empty string when present')
    minimum = parse_tnt_version(minimum_value, "tnt_min_version")
    if target < minimum:
        abort(f"requires TNT >= {minimum_value}, target is {target_version}")

# The shell needs only the already-validated relative executable path.
print(entrypoint)
PY
}

check_module_builtin() {
    module_dir=$1
    manifest="$module_dir/tnt-module.json"

    [ -d "$module_dir" ] || fail "module directory does not exist: $module_dir"
    [ -f "$manifest" ] || fail "missing manifest: $manifest"

    command -v "$PYTHON3" >/dev/null 2>&1 ||
        fail "Python 3 is required for built-in validation: $PYTHON3"
    entrypoint=$(validate_manifest "$manifest") || return 1

    entry_path="$module_dir/$entrypoint"
    [ -f "$entry_path" ] || fail "entrypoint does not exist: $entry_path"
    [ -x "$entry_path" ] || fail "entrypoint is not executable: $entry_path"
    run_handshake_check "$module_dir" "$entrypoint" "$manifest" ||
        fail "entrypoint did not return handshake.ok: $module_dir"
}

check_module() {
    module_dir=$1
    if [ -n "$CHECKER" ]; then
        [ -x "$CHECKER" ] || fail "checker is not executable: $CHECKER"
        "$CHECKER" --tnt-version "$TNT_VERSION" "$module_dir" >/dev/null ||
            fail "TNT checker rejected module: $module_dir"
    else
        check_module_builtin "$module_dir"
    fi
    echo "check-modules: ok $module_dir"
}

modules=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --tnt-version)
            [ "$#" -ge 2 ] || fail "missing value for --tnt-version"
            TNT_VERSION=$(normalize_version "$2") || fail "invalid TNT version: $2"
            shift 2
            ;;
        --checker)
            [ "$#" -ge 2 ] || fail "missing value for --checker"
            CHECKER=$2
            shift 2
            ;;
        --performance)
            PERFORMANCE=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        -*)
            fail "unknown option: $1"
            ;;
        *)
            modules="${modules}${modules:+
}$1"
            shift
            ;;
    esac
done

while [ "$#" -gt 0 ]; do
    modules="${modules}${modules:+
}$1"
    shift
done

TNT_VERSION_INPUT=$TNT_VERSION
TNT_VERSION=$(normalize_version "$TNT_VERSION_INPUT") ||
    fail "invalid TNT version: $TNT_VERSION_INPUT"

if [ -z "$modules" ]; then
    modules=$(list_default_modules)
fi

[ -n "$modules" ] || fail "no module directories found"

while IFS= read -r module_dir; do
    [ -n "$module_dir" ] || continue
    check_module "$module_dir"
done <<EOF
$modules
EOF

if [ "$PERFORMANCE" -eq 1 ]; then
    # Performance is deliberately deferred until every selected directory has
    # completed static/handshake validation (including external delegation).
    # Rebuild positional parameters as repeated option/value pairs so module
    # paths containing spaces remain distinct argv entries.
    command -v "$PYTHON3" >/dev/null 2>&1 ||
        fail "Python 3 is required for performance validation: $PYTHON3"
    [ -f "$BENCHMARK" ] || fail "benchmark script does not exist: $BENCHMARK"

    set --
    while IFS= read -r module_dir; do
        [ -n "$module_dir" ] || continue
        set -- "$@" --module-dir "$module_dir"
    done <<EOF
$modules
EOF

    benchmark_status=0
    "$PYTHON3" "$BENCHMARK" --check --idle-resources "$@" ||
        benchmark_status=$?
    if [ "$benchmark_status" -ne 0 ]; then
        echo "check-modules: performance benchmark failed" >&2
        exit "$benchmark_status"
    fi
fi
