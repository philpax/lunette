# Menu behavior

`desktop/menu` places a shared UI panel at the configured hand's wrist pose. It displays one compact Menu button while closed and a scrollable list while open. The `hand`, `size`, `offset`, `haptic`, and `expanded` settings are defined in [`config.luau`](../config.luau).

## Tracking and action list

The panel is shown only while the configured hand is tracked. Tracking loss hides the panel, closes an open list, and cancels a pending press through the UI provider. When tracking returns, the compact button becomes visible; the list stays closed. Trigger on the button opens the list. Its titlebar close action collapses the list.

Opening the list snapshots the live menu actions. A menu change refreshes the open list. Each row retains the registration token from that snapshot. Invocation supplies the token, so an action that was replaced under the same id since the row was listed cannot be invoked by the stale row. Disabled rows remain visible but do not run. Invocation and action ownership are specified by [Bindings, menu actions, and layouts](../../../../../docs/dev/lua-api.md#bindings-menu-actions-and-layouts).

The menu renders actions and owns no action policy. Plugins register actions through `lunette/menu`, which allows the renderer and broker to be replaced independently. The shipped desktop binds no key chords, so session controls remain available through VR input. See [Wrist menu](../../../../../docs/guide/desktop-configuration.md#wrist-menu) for the workflow.

## Known gaps

The shipped desktop has no keyboard chord for opening the menu. This is a deliberate shared session-control policy recorded in [Standard plugins](../../../../../docs/dev/standard-plugins.md#default-configuration).
