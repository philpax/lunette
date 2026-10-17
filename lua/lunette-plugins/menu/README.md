# Menu

Menu separates action registration from tracked wrist-menu presentation. [Action registry](action-registry/README.md) stores actions registered by plugin owners. [Wrist menu](wrist-menu/README.md) renders the wrist button and registered actions. The [toggle](toggle.luau) library registers an action that opens and closes something a plugin shows, such as a panel, keeps the action selected while it is open, and saves whether it is open through the plugin's entry, so it opens at the next start as it was left. Panels opened from the menu use it.

The [menu contract](../../lunette-contracts/menu.luau) defines registration; the renderer uses the [UI host](../../lunette-contracts/ui-host.luau), [standard kinds](../../lunette-contracts/ui-components.luau), and [frame](../../lunette-contracts/frame.luau) contracts. [Menu and keyboard workflows](../../../docs/users/desktop-configuration.md#menu-and-keyboard) define VR controls. [Shipped plugins](../README.md) defines public imports.
