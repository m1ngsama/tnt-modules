#!/bin/sh
# Validate repository release metadata and run the complete fast test suite.

set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

fail() {
    echo "release-check: $*" >&2
    exit 1
}

version=$(tr -d '\r\n' < VERSION)
[ -n "$version" ] || fail "VERSION is empty"
python3 - "$version" <<'PY' || exit 1
import re
import sys
from pathlib import Path

version = sys.argv[1]
if re.fullmatch(
    r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", version
) is None:
    print(f"release-check: invalid semantic version: {version}", file=sys.stderr)
    raise SystemExit(1)

manual_header = Path("tnt-modules.7").read_text(encoding="utf-8").splitlines()[0]
manual_pattern = (
    r'\.TH TNT-MODULES 7 "[0-9]{4}-[0-9]{2}-[0-9]{2}" '
    rf'"tnt-modules {re.escape(version)}"'
)
if re.fullmatch(manual_pattern, manual_header) is None:
    print(f"release-check: manual release does not match {version}", file=sys.stderr)
    raise SystemExit(1)
PY

if [ "$#" -gt 1 ]; then
    fail "usage: scripts/release_check.sh [vX.Y.Z]"
fi
release_ref=${1:-}
if [ -z "$release_ref" ] && [ "${GITHUB_REF_TYPE:-}" = tag ]; then
    release_ref=${GITHUB_REF_NAME:-}
fi
if [ -n "$release_ref" ] && [ "$release_ref" != "v$version" ]; then
    fail "tag $release_ref does not match VERSION $version"
fi

make man-check test

stage=$(mktemp -d "${TMPDIR:-/tmp}/tnt-modules-release.XXXXXX")
cleanup() {
    rm -rf "$stage"
}
trap cleanup EXIT INT TERM

make DESTDIR="$stage" PREFIX=/usr install
[ -f "$stage/usr/share/man/man7/tnt-modules.7" ] ||
    fail "staged install is missing tnt-modules.7"
for module in 8ball-module choose-module flip-module quote-module \
        roll-module; do
    dir="$stage/usr/libexec/tnt/modules/$module"
    [ -x "$dir/$module.sh" ] ||
        fail "staged install is missing executable $module.sh"
    [ -f "$dir/module_json.awk" ] ||
        fail "staged install is missing $module/module_json.awk"
    [ -f "$dir/$module.awk" ] ||
        fail "staged install is missing $module/$module.awk"
    [ -f "$dir/tnt-module.json" ] ||
        fail "staged install is missing $module/tnt-module.json"
done

make DESTDIR="$stage" PREFIX=/usr uninstall
[ ! -e "$stage/usr/share/man/man7/tnt-modules.7" ] ||
    fail "uninstall left tnt-modules.7"
for module in 8ball-module choose-module flip-module quote-module \
        roll-module; do
    [ ! -e "$stage/usr/libexec/tnt/modules/$module" ] ||
        fail "uninstall left the $module directory"
done

echo "release-check: tnt-modules $version is ready"
