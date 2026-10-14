# Session

Session separates frame dispatch, recovery actions, and runtime plugin management. [Frame](frame/README.md) installs LÖVR callbacks and dispatches updates, drawing, and physical-input batches while active. [Menu actions](menu-actions/README.md) registers configuration reload and the optional keyboard action. [Plugin manager](plugin-manager/README.md) provides a VR panel to inspect and manage the active composition.

The [frame contract](../../lunette-contracts/frame.luau) defines dispatch. [Menu](../../lunette-contracts/menu.luau) and [keyboard-display](../../lunette-contracts/keyboard-display.luau) support recovery controls. The manager observes [composition](../../lunette-contracts/composition.luau) and renders through [UI](../../lunette-contracts/ui.luau). [Runtime manager workflows](../../../docs/users/runtime-manager.md) define managed activation and its limits. [Shipped plugins](../README.md) defines public imports.
