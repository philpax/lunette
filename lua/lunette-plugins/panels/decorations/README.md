# Panel titlebars

Adds a titlebar to each window and monitor panel, including panels with native chrome. The titlebar is a toolkit panel attached above its panel: it takes the panel's width, follows it, and moves it when grabbed with the grip, or with the trigger on the bar outside its buttons. It shows the title, a close button, the standard Settings control, and, for a monitor mirror, buttons that restart the mirror and select monitors. The Settings control targets the native panel: quick input and transform locks flank the gear, and the popup carries the bend, axis, and both locks. A window or monitor bends about the vertical only, so the axis row is disabled with its reason and a bend away from the viewer is not offered. The old Lock input action is gone. The input lock leaves the titlebar and Settings usable; the transform lock stops the titlebar drag but not its buttons. The titlebar follows its target's curve without writing properties, and the joined outline detaches when the target curves, because that outline is a flat-panel feature.

Window close requests application closure; monitor removal stops a mirror without unplugging the host monitor. Client-drawn titlebars can coexist but cannot move the panel in space.

Titlebars take their colours and type from the toolkit theme, which the `ui-host` settings choose; the `height` option sets their height. The previous titlebar style options were removed with the previous toolkit.

[Options](config.luau) · [Monitor and titlebar workflow](../../../../docs/users/desktop-configuration.md#windows-monitors-and-workspaces)
