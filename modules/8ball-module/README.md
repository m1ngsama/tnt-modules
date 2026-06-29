# 8-Ball Module

A network-free TNT community module that answers questions like a Magic 8-Ball.

It implements `tnt.module.v1`: it reads JSONL events from stdin and writes
JSONL responses to stdout. It only acts on public messages that begin with
`/8ball`; every other message is acknowledged with a no-op.

## Syntax

```
/8ball <question>   random answer (the question text is optional)
```

It draws from the classic 20 answers (10 affirmative, 5 non-committal,
5 negative). Example results:

```
🎱 alice: It is certain.
🎱 bob: Reply hazy, try again.
🎱 cara: My sources say no.
```

## Run it manually

```sh
printf '%s\n' \
  '{"type":"handshake","protocol":"tnt.module.v1","server":{"name":"tnt","version":"1.1.0"}}' \
  '{"type":"message.created","message":{"sender":"alice","plain_text":"/8ball will it rain?"}}' \
  | ./8ball-module.sh
```

## Enable it

```sh
TNT_MODULE_PATHS=/path/to/tnt-modules/modules/8ball-module tnt
```

Randomness is seeded per question from `/dev/urandom` (PID fallback). The
leading 🎱 is decorative; the answer reads fine as plain text.
