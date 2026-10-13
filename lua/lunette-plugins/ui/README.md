# UI

The UI provider supplies owner-scoped flat VR panels, controls, and shared titlebars. It provides `lunette/ui` through `@lunette-plugins/ui`, as desktop entry `ui`. The provider does not install a draw handler; each consumer draws its own panels.

## Dependencies

The provider requires `lunette/focus`, `lunette/surfaces`, `lunette/theme`, and `lunette/frame`. The surfaces service receives UI panel offers from their owners. The theme service supplies inherited appearance and fonts.

## Configuration

The provider's `Config`, resolved `Settings`, and defaults come from [`config.luau`](config.luau). It accepts `theme` overrides and `titlebarStyle` overrides. The exact fields and validation are defined in [`theme.luau`](theme.luau) and [`titlebar-style.luau`](titlebar-style.luau); the UI types and hook signatures are owned by the [`lunette/ui` contract](../../lunette-contracts/ui.luau).

Configured definitions use `.define(config)`. Plugins create panels and controls and draw them through the contract. The [UI guide](../../../docs/guide/ui.md) gives a contract-only example.

## Rendering

[UI rendering](docs/rendering.md) specifies rounded backing, rectangular content clips, depth offsets, and titlebar frame geometry. The shared rounded perimeter implementation is specified in [rounded geometry](../theme/docs/rounded-geometry.md). The contract keeps logical control bounds and hook boundaries independent of that rendering detail; [UI panels in the Lua API](../../../docs/dev/lua-api.md#ui-panels) defines them.

## Tests

[`tests/`](tests/) covers geometry, panel behavior, controls, titlebars, themes, drawing, and validation.

## Known gaps

Geometry recorders do not rasterise edges, alpha, depth, or fonts. Intersecting or nearly coincident panels can show draw-order artefacts within the UI depth offsets. [UI rendering](docs/rendering.md#known-gaps) records these limits and the scope of the shared graphics checks.
