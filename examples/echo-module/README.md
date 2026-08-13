# Echo Module

This example demonstrates a minimal TNT module process.

It is the smallest compatibility example for TNT 1.1.0 and `tnt.module.v1`.

It reads JSONL from stdin and emits JSONL to stdout:

- `handshake` requests for `tnt.module.v1` receive `handshake.ok`.
- `message.created` events with `message.plain_text` receive a
  `message.create` response followed by `event.ok`.
- Unsupported or non-actionable events receive only `event.ok` (a no-op).
- A handshake for an unsupported protocol receives an `error` response.

The startup handshake ends with `handshake.ok`. Every event after it ends with
exactly one `event.ok`; the terminator lets TNT move
to the next event without waiting for its response timeout.

The shell implementation uses the self-contained `module_json.awk` helper to
read the protocol fields without mistaking nested metadata for top-level data.

Run it manually:

```sh
printf '%s\n' \
  '{"type":"handshake","protocol":"tnt.module.v1","server":{"name":"tnt","version":"1.1.0"}}' \
  '{"type":"message.created","message":{"plain_text":"hello"}}' \
  | ./echo-module.sh
```
