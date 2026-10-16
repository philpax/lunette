# Runtime manager

The wrist menu's Plugins action opens the shipped desktop's plugin manager. Its panel moves like [other panels](desktop-configuration.md#windows-monitors-and-workspaces); Close in its header hides it. All controls work through controllers and the shared keyboard, and a disabled control shows why it is disabled while it is pointed at.

## Entries and graph

Entries lists plugins and their states. Selecting an entry opens its details and the Enable, Disable, Reload, Recover, and Remove controls. Inspect shows diagnostics and owned resources without running plugin callbacks.

Graph shows ownership and bound-provider relationships. Pointing at a plugin or a relationship's label selects it. Drag on empty canvas pans, scroll zooms about the centre of the canvas, and Zoom, Focus, and Fit adjust the view. Relationship filters and search narrow both views; Transitive includes indirect relationships. Dependency edges identify the providers actually bound to consumers.

## Configuration and recovery

Configure edits a draft from the selected entry's schema. Apply validates the whole draft; rejection keeps the draft and its error without disturbing the live entry. Callback and custom values remain read-only. Reset restores a schema default.

Applying a valid draft restarts the entry. Replacement is not transactional: if activation fails, the old activation has already ended. Recover retries the last configuration that was active. Reload retries the current configuration. Disable withdraws an entry, and Enable starts it again. Disable, Reload, and Remove first ask for confirmation in a dialog that lists the plugins the action also unloads. Catalog can load a removed entry with its retained definition and configuration.

A cleanup failure quarantines the entry. Restarting the session releases its retained native resources.

## Protected entries

Protected entries cannot be disabled, reloaded, reconfigured, or removed. The providers they depend on are required and cannot be disabled or removed. The UI host and the standard components can still be reloaded and reconfigured, because default appearance and the recovery plugin undo a configuration of them that breaks the interface; the other required providers, such as the interaction service, cannot be changed at runtime. The shipped desktop protects the manager, the wrist menu, the keyboard, pointing, the session actions, and the recovery plugin, so the controls needed to undo a mistake stay available. Entries the protected ones do not depend on can be changed freely; the recovery plugin covers a change that breaks the interface.

## Recovery

The manager's header has a Default look button. It switches default appearance, which renders every toolkit panel with the standard controls and theme while a plugin's restyling is undone, so the manager stays usable for disabling the plugin responsible. Holding both thumbstick clicks does the same from anywhere.

The [recovery plugin](../../lua/lunette-plugins/diagnostics/recovery/README.md) shows a panel in front of the headset when the UI host or the standard components stop running, or when the UI host reports errors on many consecutive frames. It draws without the UI toolkit, so it keeps working when the toolkit does not. Its panel lists the recent errors, and controller rays operate its four actions: default appearance, which toggles the switch back to the standard widgets and theme; Reload configuration; Restore the last known good configuration; and Restart into safe mode. The panel hides once the toolkit runs again.

The last known good configuration is the composition as it stood once the UI toolkit had run for a while without errors and without further changes. The recovery plugin records it, replacing it after each later change that stays healthy. It is kept in memory and forgotten when the configuration reloads or the session restarts, so after Reload configuration the record starts again once the reloaded composition stays healthy. Restoring it puts back the recorded configuration of every entry that is not protected and the enabled state of every entry that is not required, disables entries the record does not name unless they are required, and restores removed ones from the catalog.

Restart into safe mode restarts the session into the compiled-in safe mode, which loads no plugins, starts a terminal, and shows the first window on a plain panel. Holding both triggers for two seconds, or pressing the reload key, loads the configuration again from safe mode.

## Session changes

Manager changes last only for the session. It writes no configuration or source files and installs no packages. Configuration reload starts from the entry list in `main.luau`; lasting changes belong in the [desktop configuration](desktop-configuration.md).

The [manager plugin](../../lua/lunette-plugins/session/plugin-manager/README.md) and its [schema](../../lua/lunette-plugins/session/plugin-manager/config.luau) describe startup settings. Plugin developers starting another composition use [the managed start path](../../lua/lunette-plugin/configuration-and-composition.md#start-and-manage-a-session).
