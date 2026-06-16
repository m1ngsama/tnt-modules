#!/bin/sh
# Regression tests for scripts/check_modules.sh.

set -eu

PASS=0
FAIL=0
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
STATE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/tnt-modules-test.XXXXXX")

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
    FAIL=$((FAIL + 1))
}

write_module() {
    dir=$1
    name=$2
    min_version=${3:-1.1.0}
    mkdir -p "$dir"
    cat >"$dir/tnt-module.json" <<JSON
{
  "protocol": "tnt.module.v1",
  "name": "$name",
  "version": "0.1.0",
  "tnt_min_version": "$min_version",
  "entrypoint": "./module.sh",
  "permissions": ["message:read", "message:create"],
  "events": ["message.created"]
}
JSON
    cat >"$dir/module.sh" <<'SH'
#!/bin/sh
while IFS= read -r line; do
  if printf '%s\n' "$line" | grep -q '"type"[[:space:]]*:[[:space:]]*"handshake"'; then
    printf '%s\n' '{"type":"handshake.ok","protocol":"tnt.module.v1","module":{"name":"test-module","version":"0.1.0"}}'
  else
    printf '%s\n' '{"type":"event.ok"}'
  fi
done
SH
    chmod +x "$dir/module.sh"
}

echo "=== TNT Modules Check Tests ==="

if "$ROOT/scripts/check_modules.sh" --tnt-version 1.1.0 "$ROOT/examples/echo-module" >/dev/null; then
    pass "repository echo example passes"
else
    fail_case "repository echo example passes"
fi

valid_dir="$STATE_DIR/valid"
write_module "$valid_dir" "valid-module"
if "$ROOT/scripts/check_modules.sh" --tnt-version 1.1.0 "$valid_dir" >/dev/null; then
    pass "valid module passes"
else
    fail_case "valid module passes"
fi

future_dir="$STATE_DIR/future"
write_module "$future_dir" "future-module" "9.0.0"
if "$ROOT/scripts/check_modules.sh" --tnt-version 1.1.0 "$future_dir" >/dev/null 2>&1; then
    fail_case "future TNT minimum version is rejected"
else
    pass "future TNT minimum version is rejected"
fi

bad_name_dir="$STATE_DIR/bad-name"
write_module "$bad_name_dir" "Bad_Name"
if "$ROOT/scripts/check_modules.sh" "$bad_name_dir" >/dev/null 2>&1; then
    fail_case "invalid module name is rejected"
else
    pass "invalid module name is rejected"
fi

unsafe_entry_dir="$STATE_DIR/unsafe-entry"
write_module "$unsafe_entry_dir" "unsafe-entry"
sed 's#"entrypoint": "./module.sh"#"entrypoint": "../module.sh"#' \
    "$unsafe_entry_dir/tnt-module.json" >"$unsafe_entry_dir/tnt-module.json.tmp"
mv "$unsafe_entry_dir/tnt-module.json.tmp" "$unsafe_entry_dir/tnt-module.json"
if "$ROOT/scripts/check_modules.sh" "$unsafe_entry_dir" >/dev/null 2>&1; then
    fail_case "unsafe entrypoint is rejected"
else
    pass "unsafe entrypoint is rejected"
fi

bad_handshake_dir="$STATE_DIR/bad-handshake"
write_module "$bad_handshake_dir" "bad-handshake"
cat >"$bad_handshake_dir/module.sh" <<'SH'
#!/bin/sh
printf '%s\n' '{"type":"event.ok"}'
SH
chmod +x "$bad_handshake_dir/module.sh"
if "$ROOT/scripts/check_modules.sh" "$bad_handshake_dir" >/dev/null 2>&1; then
    fail_case "bad handshake is rejected"
else
    pass "bad handshake is rejected"
fi

silent_dir="$STATE_DIR/silent"
write_module "$silent_dir" "silent-module"
cat >"$silent_dir/module.sh" <<'SH'
#!/bin/sh
exit 0
SH
chmod +x "$silent_dir/module.sh"
if "$ROOT/scripts/check_modules.sh" "$silent_dir" >/dev/null 2>&1; then
    fail_case "silent module is rejected"
else
    pass "silent module is rejected"
fi

fake_checker="$STATE_DIR/fake-checker.sh"
cat >"$fake_checker" <<'SH'
#!/bin/sh
while [ "$#" -gt 0 ]; do
  case "$1" in
    --tnt-version)
      shift 2
      ;;
    *)
      module_dir=$1
      shift
      ;;
  esac
done
[ -f "$module_dir/tnt-module.json" ]
SH
chmod +x "$fake_checker"
if "$ROOT/scripts/check_modules.sh" --checker "$fake_checker" "$valid_dir" >/dev/null; then
    pass "external TNT checker can be delegated"
else
    fail_case "external TNT checker can be delegated"
fi

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
