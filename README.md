# TNT Modules

This repository is a companion community module repository for
[TNT](../TNT), a C SSH terminal chat server.

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

The first repository release is `0.1.0`, aligned with TNT 1.1.0 module
lifecycle validation.

When deploying TNT with modules, set `TNT_MODULE_PATHS` to a colon-separated
list of module directories. Unset it to return to the plain core server.

## Layout

- `modules/`: community modules intended for reuse.
- `protocol/`: module manifest and JSONL protocol notes.
- `examples/`: small modules that demonstrate the protocol shape.

## Available modules

Self-contained, no-dependency modules under `modules/`. Each reacts only to its
own slash command and stays silent (no-op) on all other messages, so several
can run at once without interfering:

| Module | Command | What it does |
| --- | --- | --- |
| `roll-module` | `/roll [N]d<sides>[+/-K]` | Rolls dice (e.g. `/roll 2d6`, `/roll d20`, `/roll 3d6+2`). |
| `flip-module` | `/flip` | Flips a coin (heads/tails). |
| `8ball-module` | `/8ball <question>` | Replies like a Magic 8-Ball. |
| `choose-module` | `/choose a \| b \| c` | Picks one option at random. |
| `quote-module` | `/quote` | Shares a random public-domain proverb. |

Enable any subset by listing their directories in `TNT_MODULE_PATHS`
(colon-separated).

## Module Contract

A TNT module should:

1. Include a `tnt-module.json` manifest.
2. Read one JSON object per line from stdin.
3. Emit one JSON object per line to stdout.
4. Write diagnostics to stderr.
5. Exit non-zero when startup or runtime initialization fails.

The first module protocol is `tnt.module.v1`. TNT sends events such as
`message.created`, and modules can respond with actions such as
`message.create`.

See `examples/echo-module/` for the smallest useful example.

## Validation

Run the repository checks:

```sh
make test
```

When checking modules against a TNT checkout, delegate to TNT's checker:

```sh
TNT_MODULE_CHECKER=/path/to/TNT/scripts/module_check.sh make test
```

## License

This repository uses the same license text as TNT. See `LICENSE`.
