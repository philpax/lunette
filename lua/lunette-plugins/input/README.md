# Input

Input separates physical-key delivery, focus authority, virtual-keyboard creation, keyboard display, and controller attachment.

## Plugin leaves

- [Bindings](bindings/README.md) matches host chords before physical delivery.
- [Focus](focus/README.md) routes keyboard input to native sinks or local receivers.
- [Physical routing](physical-routing/README.md) delivers physical keys and committed text to the focused target.
- [Keyboard](keyboard/README.md) creates boards that caller owners place, offer, and draw.
- [Keyboard display](keyboard-display/README.md) manages the shared board's automatic and manual visibility.
- [Laser](laser/README.md) attaches controller input to interaction pointers and draws feedback.
- [Hand pointers](hand-pointers/README.md) attaches both hands to the laser provider.

The [bindings](../../lunette-contracts/bindings.luau), [focus](../../lunette-contracts/focus.luau), [keyboard](../../lunette-contracts/keyboard.luau), [keyboard-display](../../lunette-contracts/keyboard-display.luau), and [laser](../../lunette-contracts/laser.luau) contracts define service access. The [input protocol](../../lunette-contracts/docs/input.md) defines delivery and cancellation. Spatial pointer policy belongs to [interaction](../interaction/README.md).

## Public extensions

The keyboard publishes [hook types](keyboard/hooks.luau) at `@lunette-plugins/input/keyboard/hooks` and [legend drawing](keyboard/legend.luau) at `@lunette-plugins/input/keyboard/legend`. Hook types describe the keys and state supplied to configured press and draw callbacks. Legend drawing runs inside the caller's draw hook on its supplied pass and font, restores pass state, and acquires no retained resources. These extensions publish no services and expose no keyboard renderer.

[Shipped plugins and public imports](../README.md)
