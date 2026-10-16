# Runtime plugin manager

Adds a Plugins wrist-menu action for inspecting and managing the active composition in VR. The panel starts hidden and refreshes only while visible.

The panel is built with the [React-like library](../../ui/react/README.md) from the [standard kinds](../../ui/standard/README.md). The dependency graph is a kind the manager registers: a clipping canvas that draws edges with `draw:line`, with node cards and edge labels as absolutely positioned children. Disable, Reload, and Remove open a dialog panel that names the plugins the action also unloads. A failed action is reported through `lunette/notifications` when a notifications provider is loaded.

Sizes are metres. The `pixels` option of the earlier toolkit's logical canvas is removed, and a configuration that sets it is rejected; the minimum width and height are now 0.6 and 0.4 metres.

[Options](config.luau) · [Runtime manager workflow](../../../../docs/users/runtime-manager.md)
