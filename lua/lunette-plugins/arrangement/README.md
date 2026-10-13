# Arrangement persistence

This provider saves and restores panel poses, sizes, and tags. It supplies the `desktop/persistence` entry and the `lunette/arrangement` capability.

## Entry

- Module: `@lunette-plugins/arrangement` (`lua/lunette-plugins/arrangement/init.luau`).
- Desktop entry id: `desktop/persistence`.
- Capability: `lunette/arrangement` version 1, declared in [the arrangement contract](../../../lua/lunette-contracts/arrangement.luau).

## Dependencies

The provider requires `lunette/drops`, `lunette/frame`, `lunette/panels`, `lunette/rules`, and `lunette/tags`. It does not require interaction; the drops broker carries completed grabs.

## Configuration and extension

The schema in [config.luau](config.luau) defines the `file` setting and its default. The state format and version are owned by [format.luau](format.luau). The service contract defines its callable methods. Configurations can replace or disable the `desktop/persistence` entry through desktop composition.

[Persistence behaviour](docs/persistence.md) specifies matching, save timing, and refusal of unreadable or newer files. The shipped entry and its requirements are listed in [standard plugins](../../../docs/dev/standard-plugins.md#contracts-and-providers). [Standard plugins](../../../docs/dev/standard-plugins.md#default-configuration) summarizes the shipped composition. [Drops and owner-scoped registrations](../../../docs/dev/lua-api.md#pointers-and-drops) documents the shared broker guarantee.

## Tests

[Format and persistence tests](tests/format.luau) cover round-tripping, refused files, malformed entries, saving, and restoring. [Desktop arrangement tests](../desktop/arrange/tests/arrange.luau) cover interaction with layout selection.