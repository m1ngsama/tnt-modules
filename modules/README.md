# Community Modules

Place reusable TNT community modules in this directory.

Each module should live in its own subdirectory and include:

- `README.md`
- `tnt-module.json`
- The executable entrypoint declared by the manifest

Modules should avoid depending on TNT source internals. Communicate through the
documented JSONL module protocol so compatibility can track TNT protocol
versions cleanly. The current community module protocol is `tnt.module.v1`.
