# Workspaces

`@lunette-plugins/desktop/workspaces` uses tags to show one configured workspace at a time and hides panels in unselected workspace tags. The shipped desktop uses entry `desktop/workspaces`.

The entry requires `lunette/panels`, `lunette/placement`, and `lunette/tags`. Its optional menu-actions child requires `lunette/menu` and `lunette/tags`; the child registers workspace choices only when more than one workspace exists, so a menu outage leaves selection and visibility unchanged. [`config.luau`](config.luau) is the source of truth for `names` and `follow`. Names are non-empty and unique; the default list is `{ 'main' }`, and `follow` defaults to true.

[Workspace policy](docs/workspace-policy.md) specifies selection, hidden-panel overrides, and placement behavior. [Workspaces](../../../../docs/guide/desktop-configuration.md#workspaces) remains the user workflow. Shared tag and placement contracts are in [The Lua API](../../../../docs/dev/lua-api.md#tags) and [Standard plugins](../../../../docs/dev/standard-plugins.md#placement). Tests: [`workspaces.luau`](tests/workspaces.luau).

## Decisions

[Workspace policy](docs/workspace-policy.md#decisions) records the default selection, untagged-window behavior, menu outage isolation, and the decision not to ship workspace chords. Shared placement composition remains in [Standard plugins](../../../../docs/dev/standard-plugins.md#placement).
