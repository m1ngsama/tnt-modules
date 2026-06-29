# Quote Module

A network-free TNT community module that shares a random proverb in chat.

It implements `tnt.module.v1`: it reads JSONL events from stdin and writes
JSONL responses to stdout. It only acts on public messages that begin with
`/quote`; every other message is acknowledged with a no-op.

## Syntax

```
/quote     a random proverb (any extra text is ignored)
```

The built-in list is intentionally common, public-domain proverbs **without
attribution**, to avoid misquoting anyone. Example result:

```
❝ Slow and steady wins the race. ❞
```

## Run it manually

```sh
printf '%s\n' \
  '{"type":"handshake","protocol":"tnt.module.v1","server":{"name":"tnt","version":"1.1.0"}}' \
  '{"type":"message.created","message":{"sender":"alice","plain_text":"/quote"}}' \
  | ./quote-module.sh
```

## Enable it

```sh
TNT_MODULE_PATHS=/path/to/tnt-modules/modules/quote-module tnt
```

Randomness is seeded per call from `/dev/urandom` (PID fallback). The
decorative ❝ ❞ ornaments read fine as plain text.
