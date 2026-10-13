# Placement

The placement provider joins resolved window properties, panel creation, and tag membership. It also provides a hook for mapping resolved properties to panel options.

## Entry

- Module: `@lunette-plugins/placement` (`lua/lunette-plugins/placement/init.luau`).
- Desktop entry id: `placement`.
- Capability: `lunette/placement` version 1, declared in [the placement contract](../../../lua/lunette-contracts/placement.luau).

## Dependencies

The provider requires `lunette/panels`, `lunette/rules`, and `lunette/tags`. It does not adopt windows; adoption is a separate provider and consumer.

## Configuration and extension

The schema in [config.luau](config.luau) defines the `panelOptions` callback. It receives resolved placement properties, the window, and the base panel-options function. The callback can extend or replace the mapping. Contract types and placement lifecycle guarantees are specified in [the Lua API](../../../docs/dev/lua-api.md#rules-and-placement). [Placement policy](docs/placement-policy.md) describes how the shipped entries compose around the provider. [Standard plugins](../../../docs/dev/standard-plugins.md#placement) summarizes the default entry order.

## Tests

[Placement tests](tests/placement.luau) cover property/default precedence, tag membership, notifications, rollback, and lifecycle cleanup.