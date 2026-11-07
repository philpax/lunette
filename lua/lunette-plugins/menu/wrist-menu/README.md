# Wrist menu

Displays a gauntlet on the tracked wrist and a list of registered session actions. Other plugins add actions through the [menu service](../action-registry/README.md), independently of this renderer.

The menu is two [UI host](../../ui/host/README.md) panels built from the [standard kinds](../../ui/standard/README.md). The gauntlet is posed on the configured wrist each frame and wraps it like a strip, bent along its length. It holds a row of shortcuts, the menu button, and the local time as hh:mm:ss, with the shortcut and time rows equally tall so the button stays centred on the wrist point. The actions named in `shortcuts` show as quiet buttons, drawing an action's icon when it has one; the default shortcut is Hide panels. The gauntlet cannot be grabbed.

The menu button opens the list to the right of the gauntlet, as if expanded out of it, and closes it again; the button shows the selected style while the list is open. The list is flat and shows the time in its header, then the actions under a heading for each group, with groups and the actions in each in alphabetical order and actions without a group last under Other. It highlights a selected action and marks a disabled one as unavailable; it scrolls with the thumbstick when it is longer than the panel. Grabbing the list, with the grip or with the trigger on its header, tears it off the wrist: it stays where it is released and remains shown while the wrist is untracked. Its close button puts it away, and it next opens beside the gauntlet. Losing the wrist's tracking hides the gauntlet and closes a list that is on the wrist.

On the wrist, the gauntlet and the list fade with the angle between the gauntlet's face and the direction to the head: they are opaque within `facing.visible`, transparent past `facing.hidden`, and ease between them. A faded panel takes no presses, so a hand passing behind the wrist does not catch it. A torn-off list stays opaque.

The menu saves whether its list was open and whether it was torn off, so a reload or restart leaves it as it was; [placement memory](../../layout/placement-memory/README.md) returns a torn-off list to where it was left.

The `haptic` setting and the `logicalWidth`, `logicalHeight`, and `rowHeight` fields of `expanded` are removed. The UI host gives every press the same pulse, and the panel lays out its rows in metres from the theme.

[Options](config.luau) · [Menu workflow](../../../../docs/users/desktop-configuration.md#menu-and-keyboard)
