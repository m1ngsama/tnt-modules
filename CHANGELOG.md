# Changelog

## Unreleased

## 0.2.0 - 2026-06-29

### Added
- Added `modules/roll-module`, the first reusable community module: a
  network-free dice roller that replies to chat messages starting with
  `/roll` (e.g. `/roll 2d6`, `/roll d20`, `/roll 3d6+2`) and stays silent
  otherwise. Validated by the repository checker and TNT core's
  `module_check.sh`.
- Added a community "fun pack" of reusable modules under `modules/`:
  `flip-module` (`/flip`), `8ball-module` (`/8ball`), `choose-module`
  (`/choose a | b | c`), and `quote-module` (`/quote`). Each is a
  self-contained, no-dependency `tnt.module.v1` module that responds only to
  its own command and stays silent (no-op) on all other messages.
- Added `tests/test_modules_behavior.sh`, the repository's first behavioral
  test suite, which drives each module over JSONL and asserts response shapes.
  Wired into `make test`.

## 0.1.0 - 2026-06-16

### Added
- Added the first public echo module example for `tnt.module.v1`.
- Added `scripts/check_modules.sh` to validate module manifests, entrypoints,
  TNT minimum versions, permissions, events, and handshakes.
- Added a test suite for module repository validation.

### Changed
- Marked the echo example as requiring TNT 1.1.0 or newer, matching the core
  module lifecycle checker and install wizard release.
