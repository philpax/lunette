# Session actions

`@lunette-plugins/desktop/actions` registers the Reload configuration session action. The shipped desktop uses it as entry `desktop/actions`.

The entry requires `lunette/menu`. Its optional Keyboard child requires `lunette/menu` and `lunette/keyboard-display`; the child owns the Keyboard toggle action, so a keyboard-display outage leaves Reload configuration available. The entry has no configuration fields. The source of truth is [`init.luau`](init.luau).

Use menu actions to add session controls. This entry owns only its two shipped actions; the menu contract owns action registration and invocation guarantees. See [Wrist menu](../../../../docs/guide/desktop-configuration.md#wrist-menu) for the configuration workflow and [`tests/actions.luau`](tests/actions.luau) for coverage.

Shared menu action broker and frame-dispatch guarantees remain in [The Lua API](../../../../docs/dev/lua-api.md#bindings-menu-actions-and-layouts) and [Frame dispatch](../../../../docs/dev/lua-api.md#frame-dispatch).
