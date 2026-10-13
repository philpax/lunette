# Menu actions broker

The menu provider stores owner-scoped action registrations and invokes their callbacks. It renders no menu; the wrist-menu consumer is a separate entry.

## Entry

- Module: `@lunette-plugins/menu` (`lua/lunette-plugins/menu/init.luau`).
- Desktop entry id: `menu`.
- Capability: `lunette/menu` version 1, declared in [the menu contract](../../../lua/lunette-contracts/menu.luau).

## Dependencies

The provider requires no plugin capabilities and has no configuration fields. `desktop/menu` renders registered actions through the UI provider and invokes them through this broker.

## Configuration and extension

The shipped entry is listed in [standard plugins](../../../docs/dev/standard-plugins.md#contracts-and-providers). Plugins register actions through the contract. Registration state is owner-scoped; consumers update enabled and selected state explicitly. The broker's invocation, change notification, and stale-row guarantees remain in [the Lua API](../../../docs/dev/lua-api.md#bindings-menu-actions-and-layouts). [Menu action design](docs/menu-actions.md) records why storage, rendering, and session policy are separate.

## Tests

[Broker tests](tests/broker.luau) cover registration, updates, and invocation. [Validation tests](tests/validation.luau) cover rejected action shapes.