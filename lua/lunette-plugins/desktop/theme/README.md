# Runtime theme selector

`@lunette-plugins/desktop/theme` selects a named theme from the catalog and registers the Appearance actions. The shipped desktop uses entry `desktop/theme`; its definition is a factory so the session choice can survive activations while the configured preset is unchanged.

The entry requires `lunette/frame`, `lunette/menu`, `lunette/theme`, and `lunette/themes`. [`config.luau`](config.luau) owns the `preset` and sparse `overrides` schema. [`docs/theme-selection.md`](docs/theme-selection.md) specifies selection, fallback, action ordering, and missing-name reporting. Theme fields and runtime selection guarantees remain in [Runtime themes](../../../../docs/dev/lua-api.md#runtime-themes); the workflow remains in [Desktop configuration](../../../../docs/guide/desktop-configuration.md#runtime-themes).

The catalog entries come from separately composed theme plugins. The standard presets register Dark and Light; the Arcade plugin registers Arcade. Default composition remains in [Standard plugins](../../../../docs/dev/standard-plugins.md#default-configuration). Tests: [`selector.luau`](tests/selector.luau).

[Theme selection](docs/theme-selection.md#choice-and-fallback) specifies fallback and missing-name reporting.
