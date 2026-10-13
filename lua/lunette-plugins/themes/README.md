# Theme catalog

The themes provider offers an owner-scoped catalog of named complete themes. It does not select a theme. The shipped desktop uses `@lunette-plugins/themes` as entry `themes`.

## Dependencies

The provider has no required services. `theme/standard` registers Dark and Light, and `theme/arcade` registers Arcade. The desktop theme selector reads the catalog and applies a selected theme through the separate `theme` provider.

## Configuration and extension

The catalog has no configuration fields. Its config type is defined in [`init.luau`](init.luau). Plugins register complete themes with a name, label, optional order, and theme value through the [`lunette/themes` contract](../../lunette-contracts/themes.luau). The theme data shape is owned by the [`lunette/theme` contract](../../lunette-contracts/theme.luau).

## Tests

[`tests/catalog.luau`](tests/catalog.luau) checks validation, duplicate names, ordering, shipped registrations, and removal when a registering plugin is disabled.

## Known gaps

The catalog does not establish how a registered theme rasterises on a GPU. The shared [runtime theme known gaps](../theme/docs/runtime-themes.md#known-gaps) record the graphics and headset acceptance limits.

## References

[The shipped plugin catalogue](../../../docs/dev/standard-plugins.md#contracts-and-providers) describes the shipped presets and selector. [Runtime themes in the Lua API](../../../docs/dev/lua-api.md#runtime-themes) states shared selection behavior.
