# Virtual keyboards

Creates keyboards that owners place, offer, and draw. Rows and layers are configurable; layers share one board extent so switching layers does not move the display. Keys use evdev codes, with legends from the selected keymap unless overridden.

Modifier keys latch for the next non-modifier activation or toggle as locks. Changing focus, hiding, or destroying the board clears modifiers so they do not carry into another receiver.

[Options and callbacks](config.luau) · [Appearance](private/appearance.luau) · [Contract](../../../lunette-contracts/keyboard.luau) · [Input limits](../../../lunette-contracts/docs/input.md)
