# Empty-desktop hint

`@lunette-plugins/desktop/hint` draws configured text while the panel registry contains no panels. The shipped desktop uses entry `desktop/hint`.

The entry requires `lunette/frame`, `lunette/panels`, and `lunette/theme`. [`config.luau`](config.luau) is the source of truth for the text, vector position, and optional text appearance overrides. It draws in the `scene` phase at order 1 and restores pass state after drawing. Shared frame and rendering guarantees remain in [Frame dispatch](../../../../docs/dev/lua-api.md#frame-dispatch) and [Rendering](../../../../docs/dev/rendering.md). Tests: [`hint.luau`](tests/hint.luau).

## Known gaps

The hint disappears when any panel exists, including a hidden panel. Panel visibility and lifetime are defined by the shared [Panels contract](../../../../docs/dev/lua-api.md#panels).
