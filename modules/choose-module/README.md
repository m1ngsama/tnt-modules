# Choose Module

A network-free TNT community module that picks one option at random.

It implements `tnt.module.v1`: it reads JSONL events from stdin and writes
JSONL responses to stdout. It only acts on public messages that begin with
`/choose`; every other message is acknowledged with a no-op.

## Syntax

```
/choose a | b | c     pick one of the pipe-separated options at random
```

Options are split on `|` and trimmed. Fewer than two non-empty options gets a
short usage reply. Example result:

```
🤔 alice chose: coffee
```

## Run it manually

```sh
printf '%s\n' \
  '{"type":"handshake","protocol":"tnt.module.v1","server":{"name":"tnt","version":"1.1.0"}}' \
  '{"type":"message.created","message":{"sender":"alice","plain_text":"/choose tea | coffee | water"}}' \
  | ./choose-module.sh
```

## Enable it

```sh
TNT_MODULE_PATHS=/path/to/tnt-modules/modules/choose-module tnt
```

Randomness is seeded per call from `/dev/urandom` (PID fallback). The leading
🤔 is decorative; the result reads fine as plain text.
