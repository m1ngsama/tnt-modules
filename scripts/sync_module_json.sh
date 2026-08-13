#!/bin/sh
# Keep the self-contained module copies of module_json.awk in sync.

set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE="$ROOT/scripts/module_json.awk"
MODE=sync
TEMP_COPY=

cleanup() {
  [ -z "$TEMP_COPY" ] || rm -f "$TEMP_COPY"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

case "${1:-}" in
  '') ;;
  --check) MODE=check ;;
  *)
    echo "usage: scripts/sync_module_json.sh [--check]" >&2
    exit 2
    ;;
esac

for module_dir in "$ROOT"/examples/* "$ROOT"/modules/*; do
  if [ -L "$module_dir" ]; then
    echo "module-json: refusing symlink module directory: $module_dir" >&2
    exit 1
  fi
  [ -f "$module_dir/tnt-module.json" ] || continue
  destination="$module_dir/module_json.awk"
  if [ -L "$destination" ]; then
    echo "module-json: refusing symlink destination: $destination" >&2
    exit 1
  fi
  if [ "$MODE" = check ]; then
    if ! cmp -s "$SOURCE" "$destination"; then
      echo "module-json: out of sync: $destination" >&2
      exit 1
    fi
  else
    # Replace the directory entry atomically. Besides avoiding partial copies,
    # this breaks any unexpected hard link instead of overwriting its peer.
    TEMP_COPY=$(mktemp "$module_dir/.module_json.awk.XXXXXX")
    cp "$SOURCE" "$TEMP_COPY"
    chmod 0644 "$TEMP_COPY"
    mv -f "$TEMP_COPY" "$destination"
    TEMP_COPY=
    echo "module-json: synced $destination"
  fi
done
