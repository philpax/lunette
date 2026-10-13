# Keyboard provider

The keyboard provider creates owner-scoped virtual keyboards. A keyboard is a surface that its owner places, offers, and draws. The shipped desktop entry id is `keyboard`.

- Module: `@lunette-plugins/keyboard` (`lua/lunette-plugins/keyboard/init.luau`)
- Provides: `lunette/keyboard` version 3.
- Requires: `lunette/focus` version 2 and `lunette/theme` version 1.
- Configuration: `rows`, `layers`, `style`, `modifierKeys`, `locks`, `onKey`, and `drawKey`. [`config.luau`](config.luau) and [`appearance.luau`](appearance.luau) are the source of truth for option schemas and defaults. `onKey` wraps key activation; `drawKey` wraps each rendered key.
- Per-keyboard options: `onVisibilityChanged`, declared by [`lua/lunette-contracts/keyboard.luau`](../../../lua/lunette-contracts/keyboard.luau).
- Tests: [`tests/options.luau`](tests/options.luau), [`tests/draw.luau`](tests/draw.luau), [`tests/pointer.luau`](tests/pointer.luau), [`tests/routing.luau`](tests/routing.luau).
- Row layout, modifiers, actions, and drawing behavior: [Keyboard behavior](docs/keyboard.md).
- Shared virtual input routing and surface event guarantees: [Input](../../../docs/dev/input.md#keyboard-routing) and [Keyboard](../../../docs/dev/lua-api.md#keyboard).

The default rows are an ANSI layout. Key codes use the evdev vocabulary, and legends follow the active keymap unless a row supplies a label. The configuration schema permits explicit rows and named layers. The provider catalogue and default composition are in [Standard plugins](../../../docs/dev/standard-plugins.md#contracts-and-providers) and its [default configuration](../../../docs/dev/standard-plugins.md#default-configuration).
