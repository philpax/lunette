# Virtual keyboards

Creates keyboards that owners place, offer, and draw. Rows and layers are configurable; layers share one board extent so switching layers does not move the display. Keys use evdev codes, with legends from the selected keymap unless overridden.

Modifier keys latch for the next non-modifier activation or toggle as locks. Changing focus, hiding, or destroying the board clears modifiers so they do not carry into another receiver.

Appearance, rows, layers, and callbacks are configured through [config](config.luau). The public [entry](init.luau) exposes the provider and its author types. Custom key handling and drawing use the [hook types](hooks.luau); calling `base` retains the default behavior. A replacement drawing hook can use the public [legend renderer](legend.luau) without importing the private keyboard renderer.

[Contract](../../../lunette-contracts/keyboard.luau) · [Input limits](../../../lunette-contracts/docs/input.md)
