# Keyboard display

Shows one shared keyboard for focused local receivers that request one, or after an explicit show action. Configuration patches use its entry id `desktop/keyboard`, despite the module path `@lunette-plugins/keyboard-display`.

Manual show survives the end of field editing; explicit hide clears both manual and automatic visibility without clearing field contents. The keyboard stays in place as the head moves and repositions only when shown again.

[Options](config.luau) · [Contract](../../lunette-contracts/keyboard-display.luau)
