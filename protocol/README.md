# TNT Module Protocol

This document defines the compatibility contract for TNT community modules.
The first implementation target is external-process modules that exchange
JSON Lines with TNT over stdin/stdout.

## Compatibility

- Protocol version: `tnt.module.v1`
- Transport: UTF-8 JSON Lines
- Framing: one complete JSON object per line
- Direction: TNT sends events to module stdin; modules write responses to
  stdout
- Event completion: every non-handshake event ends with exactly one `event.ok`
  response
- Error stream: modules should write diagnostics to stderr
- License: protocol examples and official community modules should use TNT's
  license unless a module states stricter terms

TNT may add optional fields to existing messages. Modules must ignore unknown
fields. TNT must ignore unknown response fields unless the response type
explicitly requires them.

## Manifest

Each module declares metadata in `tnt-module.json`.

```json
{
  "protocol": "tnt.module.v1",
  "name": "echo-module",
  "version": "0.1.0",
  "tnt_min_version": "1.1.0",
  "description": "Echoes chat messages back to TNT.",
  "entrypoint": "./echo-module.sh",
  "permissions": ["message:read", "message:create"],
  "events": ["message.created"]
}
```

Required fields:

- `protocol`: protocol compatibility string. Use `tnt.module.v1`.
- `name`: stable module identifier, lowercase ASCII, `a-z`, `0-9`, and `-`.
  TNT 1.1.0 caps module names at 56 bytes so generated `module:<name>`
  senders fit the core message username limit.
- `version`: module version in `MAJOR.MINOR.PATCH` form (for example,
  `0.1.0`).
- `entrypoint`: executable path relative to the manifest directory. Current
  TNT rejects absolute paths, `..`, whitespace, control characters, and shell
  metacharacters in entrypoints.
- `permissions`: explicit capabilities requested by the module.
- `events`: event names the module wants to receive.

Optional fields:

- `description`: human-readable module summary.
- `tnt_min_version`: minimum TNT version expected by the module. TNT 1.1.0's
  module checker and install wizard use this to reject modules that require a
  newer core.
- Additional descriptive metadata may be added by module repositories, but
  modules should not depend on TNT core reading unknown metadata fields.

Current TNT `tnt.module.v1` runtime support is intentionally narrow: modules
that receive `message.created` events must request `message:read`, and modules
that emit `message.create` responses must request `message:create`.

## Transport

TNT and modules communicate with JSON Lines over stdio:

- TNT writes one JSON object per line to module stdin.
- The module writes one JSON object per line to stdout.
- The module writes logs and diagnostics to stderr.
- Messages must be UTF-8.
- Each line must contain exactly one complete JSON object.
- Keep each JSON payload at or below 4,094 bytes so the payload and newline fit
  completely in TNT's 4,096-byte line buffer.
- Current TNT runtimes accept at most eight response records for one event.
- A `message.create` `plain_text` value must decode to 1–1,023 UTF-8 bytes and
  must not contain C0 or DEL control characters.

## Handshake

After startup, TNT sends a handshake request:

```json
{"type":"handshake","protocol":"tnt.module.v1","server":{"name":"tnt","version":"1.1.0"}}
```

The module responds:

```json
{"type":"handshake.ok","protocol":"tnt.module.v1","module":{"name":"echo-module","version":"0.1.0"}}
```

If the module cannot support the requested protocol version, it responds with
an error:

```json
{"type":"error","code":"unsupported_protocol","message":"requires tnt.module.v1"}
```

## Events

TNT sends events to the module:

```json
{
  "type": "message.created",
  "message": {
    "id": "local-00000001",
    "timestamp": "2026-06-04T12:00:00Z",
    "sender": "alice",
    "kind": "text",
    "plain_text": "hello",
    "metadata": {}
  }
}
```

For every event after the handshake, the module emits zero or more action
records followed by exactly one `event.ok` terminator. For a chat response, the
complete response sequence is:

```json
{"type":"message.create","plain_text":"echo: hello"}
{"type":"event.ok"}
```

When no action is needed, the complete response is just:

```json
{"type":"event.ok"}
```

`event.ok` is a framing terminator, not an optional acknowledgement. Omitting it
forces TNT to wait for the per-event response timeout before dispatch can
continue; emitting more than one can terminate a later event accidentally. The
startup handshake is the sole exception: it ends with `handshake.ok`, not
`event.ok`.

TNT 1.1.0 and newer disable a module that floods one event with too many
responses or repeatedly emits invalid response records. Modules should keep
generated messages sparse.

## Errors

Modules can report protocol negotiation failures during the startup handshake
with:

```json
{"type":"error","code":"unsupported_protocol","message":"requires tnt.module.v1"}
```

Use stable, lowercase `code` values. Current TNT runtimes accept only
`message.create` actions and the final `event.ok` while processing an event, so
event-specific validation failures should produce a user-visible
`message.create` when useful, then `event.ok`; otherwise they should produce
only `event.ok`. Write implementation diagnostics to stderr. Every
module-created message must include a plain-text fallback through `plain_text`.
