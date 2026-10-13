# Keyboard behavior

The keyboard provider creates a board with a virtual `lunette/focus` source. The owner places, offers, and draws the board. Each key activation goes through that source. Rows and layers use evdev key codes. A key with neither a code nor an action is a spacer; a key cannot have both. A named layer action must refer to a configured layer. The `base` layer names `rows` and cannot be redefined.

Row coordinates use key units from the board's top-left corner, with y increasing downward. Each key's width and height default to one unit. The optional `x` adds a gap before the key. A row advances by its shortest key height, or one unit when it is empty. A taller key can therefore extend into the following row. A spacer contributes its width and height but does not render or receive input. Bounds are half-open: a point on the right or bottom edge belongs outside the key.

The board extent is the widest and tallest extent across the base rows and every layer. Switching layers preserves the board's overall dimensions. A layer switch cancels active pointer captures and clears cached key meshes before further input. The default rows are an ANSI layout. Labels override legends; otherwise the board asks the selected keymap seat for a character and then a keysym. A keysym without a character displays as hexadecimal.

Modifier keys are configured as an evdev-code-to-modifier map. A modifier absent from `locks` latches until the next non-modifier activation or text action. A modifier in `locks` toggles its locked state. The default map comes from `lua/lunette-contracts/keys.luau`, and default locks come from `lunette.lockingModifierNames()`. The board clears latched and locked modifiers when focus changes, when it hides, and when it is destroyed. A non-modifier activation consumes latched modifiers before receiver code runs. A route change therefore cannot carry modifiers into the next receiver.

Actions are `hide`, `layer`, `text`, `chord`, and `custom`. `hide` hides the board and asks the keyboard display to end the matching local editing route. `layer` switches rows. `text` sends committed text. `chord` sends an evdev activation with explicit modifiers. `custom` has no built-in effect; `onKey` can handle it. The `onKey` callback runs for every key activation, including action keys, and receives the board, rendered key, pointer, and a base callback. Calling the base callback performs the configured key or action. A callback that does not call the base replaces that behavior for that activation.

The `drawKey` callback runs for every key after the plate is drawn. It receives the key's current pose, style, held state, and hover state, and a base callback for the built-in renderer. The built-in draw restores pass state and transforms around each hook, including on error. Theme changes refresh the board before its next input or draw. Palette-only changes preserve captures; font or geometry changes cancel affected captures after applying the new appearance.

The default provider style uses a 0.028 m key unit, 0.002 m plate depth, 0.001 m legend depth, and 0.008 m margin. Theme tokens supply omitted appearance fields. Explicit provider style fields take precedence over theme tokens. Each keyboard scales uniformly when its width changes; the requested height is ignored. Rows, layers, style, callback types, and defaults are defined in [`config.luau`](../config.luau) and [`appearance.luau`](../appearance.luau).

## Decisions

A keyboard is owned, placed, offered, and drawn by its owner. A service-wide draw would show keyboards that the drawing owner does not offer.

Key legends use the active seat's stateless keymap queries. This keeps legends consistent with the receiver's layout, including explicit modifiers, without adding dead-key or compose state.

Layers share a stable board extent. Resizing the board during a layer change would move the display while the user changes key sets.

Keys carry `x`, `height`, and spacers, as keyboard-layout-editor's format does, so split keyboards, tall keys, and arrow clusters can be written. A uniform grid was rejected because it expresses none of them. An action is a union discriminated by `kind`, and `custom` lets a hook give a key a meaning the provider lacks.

## Known gaps

Virtual activations have no dead-key or compose engine. Local receivers have no IME or preedit protocol. Native window routing refuses text that the keymap cannot represent. These shared input limits remain in [Input known gaps](../../../../docs/dev/input.md#known-gaps).
