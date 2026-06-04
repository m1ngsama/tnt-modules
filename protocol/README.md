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
  "description": "Echoes chat messages back to TNT.",
  "entrypoint": "./echo-module.sh",
  "permissions": ["message:read", "message:create"],
  "events": ["message.created"]
}
```

Required fields:

- `protocol`: protocol compatibility string. Use `tnt.module.v1`.
- `name`: stable module identifier, lowercase ASCII, `a-z`, `0-9`, and `-`.
- `version`: module version.
- `entrypoint`: executable path relative to the manifest directory. Current
  TNT rejects absolute paths, `..`, whitespace, control characters, and shell
  metacharacters in entrypoints.
- `permissions`: explicit capabilities requested by the module.
- `events`: event names the module wants to receive.

Optional fields:

- `description`: human-readable module summary.

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

## Handshake

After startup, TNT sends a handshake request:

```json
{"type":"handshake","protocol":"tnt.module.v1","server":{"name":"tnt","version":"1.0.1"}}
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

The module responds with zero or more response messages. For a chat response:

```json
{"type":"message.create","plain_text":"echo: hello"}
```

For no-op acknowledgement:

```json
{"type":"event.ok"}
```

## Errors

Modules report recoverable request errors with:

```json
{"type":"error","code":"bad_request","message":"missing plain_text"}
```

Use stable, lowercase `code` values so TNT can route or display failures
consistently. Every module-created message must include a plain-text fallback
through `plain_text`.
