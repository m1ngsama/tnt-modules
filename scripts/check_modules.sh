#!/bin/sh
# Validate TNT module directories in this repository.

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TNT_VERSION=${TNT_MODULES_TNT_VERSION:-1.1.0}
CHECKER=${TNT_MODULE_CHECKER:-}

usage() {
    cat <<'USAGE'
Usage: scripts/check_modules.sh [--tnt-version VERSION] [--checker FILE] [MODULE_DIR ...]

With no MODULE_DIR arguments, validates module directories under examples/ and
modules/. If --checker or TNT_MODULE_CHECKER points to TNT's module_check.sh,
that checker is used. Otherwise this script runs the repository's built-in
manifest and handshake checks.
USAGE
}

fail() {
    echo "check-modules: $*" >&2
    exit 1
}

json_string_field() {
    key=$1
    file=$2
    sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "$file" |
        head -n 1
}

normalize_version() {
    version=${1#v}
    case "$version" in
        ''|*[!0-9.]*|.*|*.)
            return 1
            ;;
    esac
    printf '%s\n' "$version"
}

version_ge() {
    current=$(normalize_version "$1") || return 1
    required=$(normalize_version "$2") || return 1

    current_major=$(printf '%s\n' "$current" | awk -F. '{ print $1 + 0 }')
    current_minor=$(printf '%s\n' "$current" | awk -F. '{ print $2 + 0 }')
    current_patch=$(printf '%s\n' "$current" | awk -F. '{ print $3 + 0 }')
    required_major=$(printf '%s\n' "$required" | awk -F. '{ print $1 + 0 }')
    required_minor=$(printf '%s\n' "$required" | awk -F. '{ print $2 + 0 }')
    required_patch=$(printf '%s\n' "$required" | awk -F. '{ print $3 + 0 }')

    [ "$current_major" -gt "$required_major" ] && return 0
    [ "$current_major" -lt "$required_major" ] && return 1
    [ "$current_minor" -gt "$required_minor" ] && return 0
    [ "$current_minor" -lt "$required_minor" ] && return 1
    [ "$current_patch" -ge "$required_patch" ]
}

valid_module_name() {
    [ "${#1}" -le 56 ] || return 1
    printf '%s\n' "$1" |
        awk '/^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/ { ok = 1 } END { exit ok ? 0 : 1 }'
}

safe_entrypoint() {
    printf '%s\n' "$1" |
        awk '
            length($0) == 0 { exit 1 }
            substr($0, 1, 1) == "/" { exit 1 }
            index($0, "..") > 0 { exit 1 }
            /[[:space:][:cntrl:]\|;&`$<>\\]/ { exit 1 }
            { exit 0 }
        '
}

list_default_modules() {
    for base in "$ROOT/examples" "$ROOT/modules"; do
        [ -d "$base" ] || continue
        find "$base" -mindepth 1 -maxdepth 1 -type d | sort
    done
}

run_handshake_check() {
    module_dir=$1
    entrypoint=$2

    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/tnt-modules-check.XXXXXX")
    in_pipe="$tmpdir/stdin"
    out_file="$tmpdir/stdout"
    err_file="$tmpdir/stderr"
    writer_pid=
    module_pid=

    cleanup_handshake() {
        [ -z "$writer_pid" ] || kill "$writer_pid" 2>/dev/null || true
        [ -z "$module_pid" ] || kill "$module_pid" 2>/dev/null || true
        rm -rf "$tmpdir"
    }

    mkfifo "$in_pipe"
    case "$entrypoint" in
        */*) entry_run=$entrypoint ;;
        *) entry_run="./$entrypoint" ;;
    esac

    (
        cd "$module_dir"
        "$entry_run" <"$in_pipe" >"$out_file" 2>"$err_file"
    ) &
    module_pid=$!

    printf '%s\n' "{\"type\":\"handshake\",\"protocol\":\"tnt.module.v1\",\"server\":{\"name\":\"tnt\",\"version\":\"$TNT_VERSION\"}}" >"$in_pipe" &
    writer_pid=$!

    i=0
    while [ "$i" -lt 20 ]; do
        [ -s "$out_file" ] && break
        kill -0 "$module_pid" 2>/dev/null || break
        i=$((i + 1))
        sleep 0.1
    done

    line=$(sed -n '1p' "$out_file" 2>/dev/null || true)
    cleanup_handshake

    printf '%s\n' "$line" | grep -q '"type"[[:space:]]*:[[:space:]]*"handshake.ok"' ||
        return 1
    printf '%s\n' "$line" | grep -q '"protocol"[[:space:]]*:[[:space:]]*"tnt.module.v1"'
}

check_module_builtin() {
    module_dir=$1
    manifest="$module_dir/tnt-module.json"

    [ -d "$module_dir" ] || fail "module directory does not exist: $module_dir"
    [ -f "$manifest" ] || fail "missing manifest: $manifest"

    protocol=$(json_string_field protocol "$manifest")
    name=$(json_string_field name "$manifest")
    entrypoint=$(json_string_field entrypoint "$manifest")
    tnt_min_version=$(json_string_field tnt_min_version "$manifest")

    [ "$protocol" = "tnt.module.v1" ] ||
        fail "unsupported protocol in $module_dir: ${protocol:-missing}"
    valid_module_name "$name" ||
        fail "invalid module name in $module_dir: ${name:-missing}"
    safe_entrypoint "$entrypoint" ||
        fail "unsafe entrypoint in $module_dir: ${entrypoint:-missing}"
    [ -z "$tnt_min_version" ] ||
        version_ge "$TNT_VERSION" "$tnt_min_version" ||
        fail "$module_dir requires TNT >= $tnt_min_version, target is $TNT_VERSION"

    grep -q '"message:read"' "$manifest" ||
        fail "missing message:read permission in $module_dir"
    grep -q '"message:create"' "$manifest" ||
        fail "missing message:create permission in $module_dir"
    grep -q '"message.created"' "$manifest" ||
        fail "missing message.created event in $module_dir"

    entry_path="$module_dir/$entrypoint"
    [ -f "$entry_path" ] || fail "entrypoint does not exist: $entry_path"
    [ -x "$entry_path" ] || fail "entrypoint is not executable: $entry_path"
    run_handshake_check "$module_dir" "$entrypoint" ||
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

if [ -z "$modules" ]; then
    modules=$(list_default_modules)
fi

[ -n "$modules" ] || fail "no module directories found"

printf '%s\n' "$modules" |
while IFS= read -r module_dir; do
    [ -n "$module_dir" ] || continue
    check_module "$module_dir"
done
