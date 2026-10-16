# Wrist menu

Displays a tracked wrist button and registered session actions. Other plugins add actions through the [menu service](../action-registry/README.md), independently of this renderer.

The menu is a [UI host](../../ui/host/README.md) panel built from the [standard kinds](../../ui/standard/README.md), posed on the configured wrist each frame. Closed, it is one button. Open, it lists every action with its group, highlights a selected action, and marks a disabled one as unavailable; the list scrolls with the thumbstick when it is longer than the panel. Close returns the menu to its button, and losing the wrist's tracking hides the menu and closes the list.

The `haptic` setting and the `logicalWidth`, `logicalHeight`, and `rowHeight` fields of `expanded` are removed. The UI host gives every press the same pulse, and the panel lays out its rows in metres from the theme.

[Options](config.luau) · [Menu workflow](../../../../docs/users/desktop-configuration.md#menu-and-keyboard)
