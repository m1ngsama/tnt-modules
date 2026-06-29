# Flip Module

A tiny, network-free TNT community module that flips a coin in chat.

It implements `tnt.module.v1`: it reads JSONL events from stdin and writes
JSONL responses to stdout. It only acts on public messages that begin with
`/flip`; every other message is acknowledged with a no-op.

## Syntax

```
/flip      heads or tails (any extra text is ignored)
```

Example result:

```
🪙 alice flipped → heads
```

## Run it manually

```sh
printf '%s\n' \
  '{"type":"handshake","protocol":"tnt.module.v1","server":{"name":"tnt","version":"1.1.0"}}' \
  '{"type":"message.created","message":{"sender":"alice","plain_text":"/flip"}}' \
  | ./flip-module.sh
```

## Enable it

```sh
TNT_MODULE_PATHS=/path/to/tnt-modules/modules/flip-module tnt
```

Randomness is seeded per flip from `/dev/urandom` (PID fallback). The leading
🪙 is decorative; the result reads fine as plain text.
