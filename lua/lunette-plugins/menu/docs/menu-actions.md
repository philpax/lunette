# Menu action policy

The menu provider stores actions and renders nothing. Its shared registration, invocation, stale-token, and notification guarantees remain in [the Lua API](../../../../docs/dev/lua-api.md#bindings-menu-actions-and-layouts) and [menu.luau](../../../../lua/lunette-contracts/menu.luau).

Menu actions are a broker separate from rendering, so the wrist menu, the UI provider, or the broker can be replaced independently. Enabled and selected state are explicit owner updates, so listing runs no action code. The keyboard display observes focus metadata rather than being required by each widget, which avoids a dependency cycle.

The provider has no configuration schema. The desktop wrist-menu consumer renders the broker's action list. Its settings and workflow belong to the separate desktop entry.

## Decisions

Menu actions are separate from menu rendering. This lets a configuration replace the wrist menu, the UI provider, or the broker independently. Listing reads explicit enabled and selected state and does not run action code. The shared contract methods remain specified centrally.
