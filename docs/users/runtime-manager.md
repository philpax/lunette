# Runtime manager

The wrist menu's Plugins action opens the shipped desktop's plugin manager. Its panel moves like [other panels](desktop-configuration.md#windows-monitors-and-workspaces); the titlebar's X hides it. All controls work through controllers and the shared keyboard.

## Entries and graph

Entries lists plugins and their states. Selecting an entry opens its details and the Enable, Disable, Reload, Recover, and Remove controls. Inspect shows diagnostics and owned resources without running plugin callbacks.

Graph shows ownership and bound-provider relationships. Drag pans, scroll zooms, and Focus and Fit adjust the view. Relationship filters and search narrow both views; Transitive includes indirect relationships. Dependency edges identify the providers actually bound to consumers.

## Configuration and recovery

Configure edits a draft from the selected entry's schema. Apply validates the whole draft; rejection keeps the draft and its error without disturbing the live entry. Callback and custom values remain read-only. Reset restores a schema default.

Applying a valid draft restarts the entry. Replacement is not transactional: if activation fails, the old activation has already ended. Recover retries the last configuration that was active. Reload retries the current configuration. Disable withdraws an entry, and Enable starts it again. Catalog can load a removed entry with its retained definition and configuration.

A cleanup failure quarantines the entry. Restarting the session releases its retained native resources. Protected entries cannot be disabled or removed; the shipped desktop protects the manager and the providers and owners needed for menu, keyboard, pointing, and reload controls.

## Session changes

Manager changes last only for the session. It writes no configuration or source files and installs no packages. Configuration reload starts from the entry list in `main.luau`; lasting changes belong in the [desktop configuration](desktop-configuration.md).

The [manager plugin](../../lua/lunette-plugins/desktop/manager/README.md) and its [schema](../../lua/lunette-plugins/desktop/manager/config.luau) describe startup settings. Plugin developers starting another composition use [the managed start path](../../lua/lunette-plugin/configuration-and-composition.md#start-and-manage-a-session).
