# Panel titlebars

Adds a titlebar to each window and monitor panel that has no chrome of its own. The titlebar is a toolkit panel attached above its panel: it takes the panel's width, follows it, and moves it when grabbed with the grip, or with the trigger on the bar outside its buttons. It shows the title, a close button, and, for a monitor mirror, buttons that restart the mirror and select monitors. Where the panel service can draw an outline, which it can around a flat panel, the outline joins the titlebar.

Window close requests application closure; monitor removal stops a mirror without unplugging the host monitor. Client-drawn titlebars can coexist but cannot move the panel in space.

Titlebars take their colours and type from the toolkit theme, which the `ui-host` settings choose; the `height` option sets their height. The previous titlebar style options were removed with the previous toolkit.

[Options](config.luau) · [Monitor and titlebar workflow](../../../../docs/users/desktop-configuration.md#windows-monitors-and-workspaces)
