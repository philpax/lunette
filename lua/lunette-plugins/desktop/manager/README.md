# Runtime plugin manager

Provides a VR panel for inspecting and managing the active plugin composition. The Plugins wrist-menu action opens it; the [runtime manager guide](../../../../docs/guide/runtime-manager.md) covers the workflow.

| Requires |
| --- |
| `lunette/composition`, `lunette/frame`, `lunette/ui`, `lunette/theme`, and `lunette/menu` |

The panel starts hidden. While visible, it refreshes its runtime snapshot at the configured interval instead of every frame; hidden panels do not refresh. This avoids repeating inspection work faster than the panel can display updates.

[Options](config.luau) · [Composition contract](../../../../docs/dev/lua-api.md#composition).
