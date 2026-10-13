# Runtime theme selector

Selects a theme from the catalog and registers Appearance actions for available themes. Configure the [`preset` and sparse `overrides`](config.luau); the standard presets are Dark and Light, and the Arcade plugin adds Arcade.

| Requires |
| --- |
| `lunette/frame`, `lunette/menu`, `lunette/theme`, and `lunette/themes` |

A missing theme name falls back to the configured preset when available, then to the theme provider's base theme. A user selection lasts across entry activations, but not source reload. See [Runtime themes](../../../../lua/lunette-contracts/panels-and-ui.md#themes) and [Desktop configuration](../../../../docs/guide/desktop-configuration.md#themes-and-appearance).
