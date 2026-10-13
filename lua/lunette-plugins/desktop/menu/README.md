# Wrist menu

`@lunette-plugins/desktop/menu` renders the tracked wrist Menu button and the registered session action list. The shipped desktop uses entry `desktop/menu`.

The entry requires `lunette/ui`, `lunette/frame`, and `lunette/menu`. [`config.luau`](config.luau) is the source of truth for hand, panel size and offset, haptic values, and expanded-list dimensions. Plugins extend the list through the menu broker, not through this renderer. The broker and shared input behavior are specified in [Bindings, menu actions, and layouts](../../../../docs/dev/lua-api.md#bindings-menu-actions-and-layouts) and [Surface pointer input](../../../../docs/dev/input.md#surface-pointer-input).

[Menu behavior](docs/menu-behavior.md) specifies tracking loss and action-list updates. [Wrist menu](../../../../docs/guide/desktop-configuration.md#wrist-menu) describes the user workflow. Tests: [`vr.luau`](tests/vr.luau).

The shipped menu has no keyboard shortcut; see [Menu behavior](docs/menu-behavior.md#known-gaps).
