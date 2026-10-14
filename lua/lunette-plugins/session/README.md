# Session

Session separates frame dispatch, recovery actions, and runtime plugin management.

## Plugin leaves

- [Frame](frame/README.md) installs LÖVR callbacks and dispatches updates, drawing, and physical-input batches while its provider is active.
- [Menu actions](menu-actions/README.md) registers configuration reload and the optional keyboard action.
- [Plugin manager](plugin-manager/README.md) supplies a VR panel for inspecting and managing the active composition.

The [frame contract](../../lunette-contracts/frame.luau) defines dispatch. The [menu](../../lunette-contracts/menu.luau) and [keyboard-display](../../lunette-contracts/keyboard-display.luau) contracts support recovery controls. The manager observes the [composition contract](../../lunette-contracts/composition.luau) and renders through [UI](../../lunette-contracts/ui.luau). [Runtime manager workflows](../../../docs/users/runtime-manager.md) define managed activation and its limits.

[Shipped plugins and public imports](../README.md)
