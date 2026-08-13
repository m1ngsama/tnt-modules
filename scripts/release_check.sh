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

version = sys.argv[1]
if re.fullmatch(
    r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", version
) is None:
    print(f"release-check: invalid semantic version: {version}", file=sys.stderr)
    raise SystemExit(1)
PY

grep -Fq "current repository release is \`$version\`" README.md ||
    fail "README release does not match $version"
grep -Eq "^## $version - [0-9]{4}-[0-9]{2}-[0-9]{2}$" CHANGELOG.md ||
    fail "CHANGELOG has no dated $version release section"

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

make test
echo "release-check: tnt-modules $version is ready"
