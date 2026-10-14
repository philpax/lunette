# Menu

Menu separates action registration from tracked wrist-menu presentation.

## Plugin leaves

- [Action registry](action-registry/README.md) stores actions registered by plugin owners.
- [Wrist menu](wrist-menu/README.md) renders the wrist button and registered actions.

The [menu contract](../../lunette-contracts/menu.luau) defines action registration. The renderer uses the [UI](../../lunette-contracts/ui.luau) and [frame](../../lunette-contracts/frame.luau) contracts. [Menu and keyboard workflows](../../../docs/users/desktop-configuration.md#menu-and-keyboard) define the VR session controls.

[Shipped plugins and public imports](../README.md)
