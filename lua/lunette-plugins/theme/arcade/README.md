# Arcade theme

This consumer registers the complete Arcade theme with the theme catalog. The shipped desktop uses `@lunette-plugins/theme/arcade` as entry `theme/arcade`. Disabling this entry removes the Arcade choice without changing other registrations.

## Dependencies

The plugin requires `lunette/themes`. The catalog provider must be enabled for the Arcade choice to be available. The preset uses the bundled Space Mono Regular font at `fonts/SpaceMono-Regular.ttf`; its license is in [`fonts/OFL.txt`](fonts/OFL.txt).

## Configuration

The plugin has no configuration fields. Its empty config type is defined in [`init.luau`](init.luau), and the complete preset is defined in [`preset.luau`](preset.luau). The theme shape is owned by the [`lunette/theme` contract](../../../lunette-contracts/theme.luau).

## Tests

The [catalog suite](../../themes/tests/catalog.luau) verifies Arcade registration and its removal when this plugin is disabled.

## Known gaps

Preset registration does not establish GPU rendering behavior. The shared [rounded geometry known gaps](../docs/rounded-geometry.md#known-gaps) record that geometry tests do not rasterise edges, alpha, depth, or fonts.

## References

[The shipped plugin catalogue](../../../../docs/dev/standard-plugins.md#contracts-and-providers) describes the catalog and selector. [Rounded geometry](../docs/rounded-geometry.md) describes the shared rendering geometry used by theme consumers.
