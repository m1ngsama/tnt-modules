# Changelog

## Unreleased

### Added

- Added a reproducible, standard-library Python benchmark for cold process
  startup, warm command-event latency, stdout volume, and co-resident idle
  resources. It reports p50, p95, and p99 latency plus per-process-group RSS,
  CPU, and process counts in human-readable and schema-versioned JSON formats;
  `make perf-check` enforces the selected profile's regression redlines.
- Added real slash-command benchmark workloads to every reusable module
  manifest and require the expected `message.create` action before event
  completion, so the benchmark measures command handlers rather than no-op
  paths.
- Added benchmark regression tests and Linux/macOS CI budget checks. CI retains
  `module-performance.json` as a platform-specific artifact even when a budget
  check fails.
- Added an eight-slot idle-resource profile that includes child processes,
  gates per-slot and aggregate RSS plus idle CPU, and runs for ten seconds on
  both CI platforms. Added `PERFORMANCE.md` with the Issue #7 target
  environment, measurement contract, CI reports, and remaining concurrency,
  sustained-load, and core-isolation gaps.
- Added an explicit `scripts/check_modules.sh --performance` profile. After all
  built-in or delegated static checks finish, it invokes the shared benchmark
  once for every checked directory to enforce latency, output, and eight-slot
  idle-resource budgets; the default checker remains fast.

### Fixed

- Updated the echo example and every bundled community module to emit
  `event.ok` immediately after any `message.create` action. This explicitly
  terminates each event and avoids waiting for TNT's per-event response timeout
  after generated messages.
- Replaced grep/sed-based protocol field matching with a shared, self-contained
  POSIX awk JSON parser. Escaped quotes and backslashes are now decoded
  correctly, and nested metadata fields can no longer impersonate top-level
  event fields. The parser validates UTF-8, rejects duplicate keys, preserves
  unknown extension fields, and rejects controls only when they occur in a
  requested transport string.
- Changed unknown and non-actionable non-handshake inputs to no-op with
  `event.ok`, avoiding responses that the current TNT runtime treats as
  invalid. Unsupported protocol handshakes still return an error.
- Preserved literal backslashes when sender, dice, and choice text crosses awk
  boundaries, made JSON escaping portable across one-true-awk, mawk, and gawk
  POSIX mode, and retained the intended Unicode result symbols.
- Capped echo and choose responses at TNT's 1,023-byte decoded-text limit with
  UTF-8-aware truncation, so maximum-size valid events cannot produce responses
  that TNT rejects.
- Hardened checker, behavior-test, and benchmark process cleanup to terminate
  complete process groups, including stubborn descendants, and reject
  unsolicited output left behind after a startup handshake.

### Changed

- Reworked the built-in module checker to parse manifests and handshakes as
  strict JSON, validate required field types and exact array membership, reject
  duplicate keys and malformed versions, verify handshake name/version against
  the manifest, and match TNT's JSONL size boundary.
- Expanded behavior and checker regression coverage across every reusable
  module and the echo example, including exact event framing, unsupported
  handshakes, unknown events, escaped strings, nested-key spoofing, malformed
  manifests, process timeouts, transport boundaries, and checker delegation.
- Clarified the protocol and module documentation that `event.ok` is the
  required terminator for every non-handshake event, including no-op events.

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
  test suite, which drives the four fun-pack modules over JSONL and asserts
  response shapes. Wired into `make test`.

## 0.1.0 - 2026-06-16

### Added

- Added the first public echo module example for `tnt.module.v1`.
- Added `scripts/check_modules.sh` to validate module manifests, entrypoints,
  TNT minimum versions, permissions, events, and handshakes.
- Added a test suite for module repository validation.

### Changed

- Marked the echo example as requiring TNT 1.1.0 or newer, matching the core
  module lifecycle checker and install wizard release.
