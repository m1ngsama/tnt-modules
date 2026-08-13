# Community Modules

Place reusable TNT community modules in this directory.

Each module should live in its own subdirectory and include:

- `README.md`
- `tnt-module.json`
- The executable entrypoint declared by the manifest

Modules should avoid depending on TNT source internals. Communicate through the
documented JSONL module protocol so compatibility can track TNT protocol
versions cleanly. The current community module protocol is `tnt.module.v1`.

For every event after the startup handshake, emit zero or more action records
and then exactly one `{"type":"event.ok"}` record. Emit `event.ok` immediately
when the module has no action to take; it is the event terminator, not an
optional acknowledgement.

The bundled shell modules carry a self-contained `module_json.awk` parser. Its
canonical source is `scripts/module_json.awk`; after changing it, run
`scripts/sync_module_json.sh` and verify the copies with
`scripts/sync_module_json.sh --check`.
