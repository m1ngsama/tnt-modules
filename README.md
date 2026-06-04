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

When deploying TNT with modules, set `TNT_MODULE_PATHS` to a colon-separated
list of module directories. Unset it to return to the plain core server.

## Layout

- `modules/`: community modules intended for reuse.
- `protocol/`: module manifest and JSONL protocol notes.
- `examples/`: small modules that demonstrate the protocol shape.

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

## License

This repository uses the same license text as TNT. See `LICENSE`.
