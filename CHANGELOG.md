# Changelog

## Unreleased

### Added
- Added `modules/roll-module`, the first reusable community module: a
  network-free dice roller that replies to chat messages starting with
  `/roll` (e.g. `/roll 2d6`, `/roll d20`, `/roll 3d6+2`) and stays silent
  otherwise. Validated by the repository checker and TNT core's
  `module_check.sh`.

## 0.1.0 - 2026-06-16

### Added
- Added the first public echo module example for `tnt.module.v1`.
- Added `scripts/check_modules.sh` to validate module manifests, entrypoints,
  TNT minimum versions, permissions, events, and handshakes.
- Added a test suite for module repository validation.

### Changed
- Marked the echo example as requiring TNT 1.1.0 or newer, matching the core
  module lifecycle checker and install wizard release.
