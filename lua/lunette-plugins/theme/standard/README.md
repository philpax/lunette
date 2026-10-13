# Standard themes

This consumer registers the Dark and Light complete themes with the theme catalog. The shipped desktop uses `@lunette-plugins/theme/standard` as entry `theme/standard`.

## Dependencies

The plugin requires `lunette/themes`. The catalog provider must be enabled for these choices to be available. The plugin registers `dark` before `light`; the desktop theme selector is a separate entry.

## Configuration

The plugin has no configuration fields. Its empty config type is defined in [`init.luau`](init.luau). The named presets are defined in [`presets.luau`](presets.luau), and the theme shape is owned by the [`lunette/theme` contract](../../../lunette-contracts/theme.luau).

## Tests

The [catalog suite](../../themes/tests/catalog.luau) verifies the shipped registration order and removal when a preset plugin is disabled.

## Known gaps

Preset registration does not establish GPU rendering behavior. The shared [rounded geometry known gaps](../docs/rounded-geometry.md#known-gaps) record that geometry tests do not rasterise edges, alpha, depth, or fonts.

## References

[The shipped plugin catalogue](../../../../docs/dev/standard-plugins.md#contracts-and-providers) describes the catalog and selector. [Rounded geometry](../docs/rounded-geometry.md) describes the shared rendering geometry used by theme consumers.
