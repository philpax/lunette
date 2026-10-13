# Panels

The panels provider creates and draws window and monitor panels. It supplies Lua-side geometry, picking, visibility, theme appearance, and optional composition-layer claims. The shipped desktop uses `@lunette-plugins/panels` as entry `panels`.

## Dependencies

The provider requires `lunette/theme`. The shipped desktop's `desktop/render` consumer updates and draws panels. A separate child offers the shown panels as pointer surfaces and requires `lunette/surfaces`; without that child, panels continue drawing but pointers cannot pick them.

## Configuration

The provider's `Config`, resolved `Settings`, and defaults come from [`config.luau`](config.luau). The schema supports `style`, `priority`, `height`, `aspect`, `chrome`, and `rendering`. `rendering` is `plane` by default or `layer`. See [panels in the Lua API](../../../docs/dev/lua-api.md#panels) for panel options and shared guarantees.

Configured definitions use `.define(config)`. The schema remains the source of truth for accepted fields and defaults. Panel creation options are defined by the [`lunette/panels` contract](../../lunette-contracts/panels.luau).

## Rendering

[Panel rendering](docs/rendering.md) specifies child-surface ordering and clipping, layer fallback, and joined flat frames. [Rounded geometry](../theme/docs/rounded-geometry.md) specifies the shared rounded perimeter algorithm. [Rendering](../../../docs/dev/rendering.md) retains shared scene and composition-layer guarantees.

## Tests

The panel suites are in [`tests/`](tests/), including child geometry, drawing, panel behavior, and shapes.

## Known gaps

A popup that extends beyond its window can be clipped and cannot be pointed at outside the panel. A window that always shows a subsurface never holds a composition layer, and `window:stabilize()` copies only the window's own surface. Window buffer transforms are not applied when panels draw content, so a transformed buffer appears untransformed and a crop can sample the wrong region. [Panel rendering](docs/rendering.md#known-gaps) records these limits.
