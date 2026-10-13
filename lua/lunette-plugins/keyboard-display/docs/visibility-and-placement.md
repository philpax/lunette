# Visibility and placement

The display creates and reuses one keyboard. A focused local target with `wantsKeyboard` requests automatic visibility. The display hides automatically when that target stops being current, unless a manual show is active. Manual show survives the end of field editing; explicit hide clears both intents. Hiding preserves field contents, and a later field reuses the board.

Hide actions blur only the local target that still holds focus. They do not blur a newer target. A visible keyboard stays at its placement when the head moves; it is positioned again only when it becomes visible.

The display observes focus metadata instead of being required by each widget, avoiding a dependency cycle. One shared board avoids duplicate keyboards and repositioning on field changes.
