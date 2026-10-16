# Wrist menu

Displays a tracked wrist button and registered session actions. Other plugins add actions through the [menu service](../action-registry/README.md), independently of this renderer.

The menu is a [UI host](../../ui/host/README.md) panel built from the [standard kinds](../../ui/standard/README.md), posed on the configured wrist each frame. Closed, it is one button. Open, it lists every action with its group, highlights a selected action, and marks a disabled one as unavailable; the list scrolls with the thumbstick when it is longer than the panel. Grabbing the open menu, with the grip or with the trigger on its header, tears it off the wrist: it stays where it is released and remains shown while the wrist is untracked. The close button returns the menu to its button on the wrist. The closed button cannot be grabbed. Losing the wrist's tracking hides a menu that is on the wrist and closes its list.

The `haptic` setting and the `logicalWidth`, `logicalHeight`, and `rowHeight` fields of `expanded` are removed. The UI host gives every press the same pulse, and the panel lays out its rows in metres from the theme.

[Options](config.luau) · [Menu workflow](../../../../docs/users/desktop-configuration.md#menu-and-keyboard)
