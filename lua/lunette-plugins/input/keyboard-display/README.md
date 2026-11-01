# Keyboard display

Shows one shared keyboard for focused local receivers that request one, or after an explicit show action. Configuration patches use its entry id `desktop/keyboard`, despite the module path `@lunette-plugins/input/keyboard-display`.

Manual show survives the end of field editing; explicit hide clears both manual and automatic visibility without clearing field contents. The keyboard stays in place as the head moves and repositions only when shown again. The display saves whether the keyboard was shown by an explicit show action, so such a keyboard shows again when the session starts or reloads; a keyboard shown only for a focused field does not. [Placement memory](../../layout/placement-memory/README.md) returns it to where it was left and keeps its size.

A titlebar above the shown keyboard names it and has a Close button, which hides the keyboard as explicit hide does. The titlebar is a [UI host](../../ui/host/README.md) panel built from the [standard kinds](../../ui/standard/README.md). It is attached to the keyboard, as window titlebars are to their windows: it spans the keyboard, or grows past a narrow one to fit its title and button, and a trigger drag on its empty space carries the keyboard. It is not joined to the keyboard's frame, because the UI host's panels do not attach to another surface's frame.

[Options](config.luau) · [Contract](../../../lunette-contracts/keyboard-display.luau)
