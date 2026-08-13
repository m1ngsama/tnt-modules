# TNT Modules

This repository is a companion community module repository for
[TNT](https://github.com/m1ngsama/TNT), a C SSH terminal chat server.

TNT modules are external-process components. TNT starts a module process,
sends newline-delimited JSON messages to the module's standard input, and
reads newline-delimited JSON messages from the module's standard output.

TNT core stays deliberately basic and broadly compatible. Modules are where
personalized workflows, richer visuals, and terminal-specific experience
improvements should live.

Module compatibility tracks TNT protocol versions. A module declares the TNT
module protocol string it supports in its manifest, currently
`tnt.module.v1`, and TNT core can use that declaration to decide whether the
module is compatible with the running server.

The current repository release is `0.2.0`. Its modules require TNT 1.1.0 or
newer and use the stable `tnt.module.v1` protocol.

When deploying TNT with modules, set `TNT_MODULE_PATHS` to a colon-separated
list of module directories. Unset it to return to the plain core server.

## Layout

- `modules/`: community modules intended for reuse.
- `protocol/`: module manifest and JSONL protocol notes.
- `examples/`: small modules that demonstrate the protocol shape.

## Available modules

Self-contained, no-dependency modules under `modules/`. Each reacts only to its
own slash command and emits no action (only the required `event.ok`) for all
other messages, so several can run at once without interfering:

| Module | Command | What it does |
| --- | --- | --- |
| `roll-module` | `/roll [N]d<sides>[+/-K]` | Rolls dice expressions. |
| `flip-module` | `/flip` | Flips a coin (heads/tails). |
| `8ball-module` | `/8ball [question]` | Replies like a Magic 8-Ball. |
| `choose-module` | `/choose a \| b \| c` | Picks one option at random. |
| `quote-module` | `/quote` | Shares a random public-domain proverb. |

Enable any subset by listing their directories in `TNT_MODULE_PATHS`
(colon-separated).

## Module Contract

A TNT module should:

1. Include a `tnt-module.json` manifest.
2. Read one JSON object per line from stdin.
3. Emit zero or more action objects for each event, then exactly one
   `{"type":"event.ok"}` terminator, with one JSON object per stdout line.
4. Write diagnostics to stderr.
5. Exit non-zero when startup or runtime initialization fails.

The first module protocol is `tnt.module.v1`. TNT sends events such as
`message.created`, and modules can respond with actions such as
`message.create`. The startup handshake ends with `handshake.ok`; every event
after the handshake ends with `event.ok`, including events that require no
action.

See `examples/echo-module/` for the smallest useful example.

## Validation

Run the repository checks:

```sh
make test
```

The default checker stays fast. To run its optional full performance profile
after every selected module has passed manifest and handshake validation:

```sh
scripts/check_modules.sh --performance
```

That profile invokes the shared benchmark once for all checked directories and
enforces startup/event latency, output volume, bounded 1/4/8-slot load, and the
eight-slot idle RSS/CPU budgets. Explicit module paths, including paths
containing spaces, are passed to the same benchmark rather than measured by a
separate checker implementation.

Repository validation and performance tooling require Python 3.10 or newer.
The packaged modules themselves remain self-contained and require only a POSIX
shell and standard Unix tools.

Run the quick startup/event benchmark, or enforce its latency and output
redlines:

```sh
make perf
make perf-check
```

Run the fixed-rate 1/4/8-slot load profile or the eight-slot idle RSS/CPU
profile:

```sh
make perf-load
make perf-resources
```

To match CI's complete enforced scope and preserve it as JSON:

```sh
make perf-check PERF_ARGS="--load --idle-resources \
  --json-output module-performance.json"
```

See [PERFORMANCE.md](PERFORMANCE.md) for the target environment, budgets,
measurement method, CI artifacts, and current coverage gaps.

When checking modules against a TNT checkout, delegate to TNT's checker:

```sh
TNT_MODULE_CHECKER=/path/to/TNT/scripts/module_check.sh make test
```

`scripts/check_modules.sh --checker /path/to/module_check.sh --performance`
first delegates every static check and then runs the same local full performance
profile. Omitting `--performance` preserves the quick checker-only behavior.

## License

This repository uses the same license text as TNT. See `LICENSE`.
