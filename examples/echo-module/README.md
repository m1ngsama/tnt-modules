# Echo Module

This example demonstrates a minimal TNT module process.

It is the smallest compatibility example for TNT 1.1.0 and `tnt.module.v1`.

It reads JSONL from stdin and emits JSONL to stdout:

- `handshake` requests for `tnt.module.v1` receive `handshake.ok`.
- `message.created` events with `message.plain_text` receive a
  `message.create` response.
- Unsupported inputs receive an `error` response.

The shell implementation is intentionally small and uses simple text matching.
Production modules should use a JSON parser and preserve unknown fields.

Run it manually:

```sh
printf '%s\n' \
  '{"type":"handshake","protocol":"tnt.module.v1","server":{"name":"tnt","version":"1.1.0"}}' \
  '{"type":"message.created","message":{"plain_text":"hello"}}' \
  | ./echo-module.sh
```
