# Roll Module

A small, network-free TNT community module that rolls dice in chat.

It implements `tnt.module.v1`: it reads JSONL events from stdin and writes
JSONL responses to stdout. It only acts on public messages that begin with
`/roll`; every other message is acknowledged with a no-op so the module stays
quiet during normal conversation.

## Syntax

The dice spec is case-insensitive (`d` or `D`):

```
/roll              one 6-sided die (1d6)
/roll d20          one 20-sided die
/roll 3d6          three 6-sided dice, summed
/roll 2d6+3        with a flat +/- modifier
```

Bounds: 1–20 dice, 2–1000 sides, modifier within ±10000. Anything outside the
syntax or bounds gets a short usage reply.

Example results:

```
🎲 alice rolled d20 → 14
🎲 alice rolled 3d6 → 4 + 2 + 6 = 12
🎲 alice rolled 2d6+3 → 5 + 1 (+3) = 9
```

## Run it manually

```sh
printf '%s\n' \
  '{"type":"handshake","protocol":"tnt.module.v1","server":{"name":"tnt","version":"1.1.0"}}' \
  '{"type":"message.created","message":{"sender":"alice","plain_text":"/roll 2d6"}}' \
  | ./roll-module.sh
```

## Enable it

Point TNT at this module directory (colon-separated for multiple modules):

```sh
TNT_MODULE_PATHS=/path/to/tnt-modules/modules/roll-module tnt
```

## Implementation notes

The result text is always plain UTF-8 (the leading 🎲 is decorative and the
line reads fine without it), satisfying the protocol's plain-text requirement.
Randomness is seeded per roll from `/dev/urandom` (falling back to the PID),
so repeated rolls within the same second still differ. JSON output is escaped;
production modules handling untrusted input should prefer a real JSON parser.
