# Keyboard behavior

Rows use key units from the board's top-left corner. Keys can vary in size, add a gap, or act as spacers; a uniform grid cannot represent a physical keyboard's irregular rows. Layers share one board extent, so changing layers does not move the display while the key set changes. A layer change cancels pointer captures and rebuilds key meshes.

Keys use evdev codes. Legends follow the selected keymap seat unless a row supplies a label. Modifier keys latch until the next non-modifier activation, or toggle when configured as locks. The board clears modifiers when focus changes, hides, or is destroyed, so modifiers do not carry into another receiver.

Actions can hide the board, switch layers, send text, send a chord, or invoke custom behavior. `onKey` runs for every activation and can replace the built-in action by not calling its base callback. `drawKey` runs after the key plate and can replace the built-in renderer.

The default layout is ANSI. Explicit appearance values take precedence over theme tokens. [Options](../config.luau) and [appearance](../appearance.luau) define configurable rows, layers, and styles.

Virtual typing follows the [shared input limitations](../../../../docs/dev/input.md#known-gaps).
