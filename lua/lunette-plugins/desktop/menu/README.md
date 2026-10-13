# Wrist menu

Displays a tracked wrist button and the session actions registered by other plugins. Configure the [`hand`, panel size and offset, haptics, and expanded-list dimensions](config.luau).

| Requires |
| --- |
| `lunette/ui`, `lunette/frame`, and `lunette/menu` |

Plugins add actions through the [menu action contract](../../../../docs/dev/lua-api.md#bindings-menu-actions-and-layouts), not through this renderer. The shipped menu has no keyboard shortcut; session controls remain available through VR input. See [Wrist menu](../../../../docs/guide/desktop-configuration.md#wrist-menu).
