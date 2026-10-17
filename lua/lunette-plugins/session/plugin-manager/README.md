# Runtime plugin manager

Adds a Plugins wrist-menu action for inspecting and managing the active composition in VR. The panel starts hidden and refreshes only while visible.

The panel is built with the [React-like library](../../ui/react/README.md) from the [standard kinds](../../ui/standard/README.md). The dependency graph is a kind the manager registers: a clipping canvas that draws edges with `draw:line`, with node cards and edge labels as absolutely positioned children. Disable, Reload, and Remove open a dialog panel that names the plugins the action also unloads. A failed action is reported through `lunette/notifications` when a notifications provider is loaded.

The Configure tab places the attributed settings outlet that [`@lunette-contracts/plugin-manager`](../../../lunette-contracts/plugin-manager.luau) declares, with the selected entry's id and plugin definition name, below the options. A plugin contributes its own settings page there and shows it only for its own entry. Each page sits in a frame that names the contributing plugin, and the outlet never holds the manager's lifecycle controls.

Apply records the entry's changed options as [saved settings](../../storage/README.md#saved-settings). Configure marks saved options and forgets them, and the Saved tab lists and forgets every saved setting through the composition service's `savedSettings` and `forgetSaved`.

Sizes are metres. The `pixels` option of the earlier toolkit's logical canvas is removed, and a configuration that sets it is rejected; the minimum width and height are now 0.6 and 0.4 metres.

[Options](config.luau) · [Runtime manager workflow](../../../../docs/users/runtime-manager.md)
