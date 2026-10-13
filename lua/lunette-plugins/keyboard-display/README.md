# Keyboard display

The keyboard display creates and presents one session keyboard when requested by a focused local receiver or by an explicit show action. The shipped desktop entry id is `desktop/keyboard`.

- Module: `@lunette-plugins/keyboard-display` (`lua/lunette-plugins/keyboard-display/init.luau`)
- Provides: `lunette/keyboard-display` version 1.
- Requires: `lunette/frame` version 2, `lunette/focus` version 2, `lunette/keyboard` version 3, `lunette/surfaces` version 1, and `lunette/ui` version 3.
- Configuration: `placement.distance`, `placement.drop`, and `placement.tilt`. [`config.luau`](config.luau) is the source of truth for defaults and types.
- Tests: [`tests/keyboard.luau`](tests/keyboard.luau), [`tests/vr.luau`](tests/vr.luau), [`tests/display.luau`](tests/display.luau).
- Visibility and placement policy: [Visibility and placement](docs/visibility-and-placement.md).
- Shared focus and virtual keyboard contracts: [Keyboard routing](../../../docs/dev/input.md#keyboard-routing) and [Keyboard](../../../docs/dev/lua-api.md#keyboard).

This module path differs from its desktop entry id: the module is `@lunette-plugins/keyboard-display`, while configuration patches name `desktop/keyboard`. The catalogue and default entry list are in [Standard plugins](../../../docs/dev/standard-plugins.md#contracts-and-providers) and its [default configuration](../../../docs/dev/standard-plugins.md#default-configuration).
