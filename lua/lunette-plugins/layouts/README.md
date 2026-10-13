# Layouts broker

The layouts provider stores named layout registrations and applies them to the live panels supplied by a caller. It does not provide a layout algorithm or arrange panels on its own. The provider and contributor entries are listed in [standard plugins](../../../docs/dev/standard-plugins.md#contracts-and-providers).

## Entry

- Module: `@lunette-plugins/layouts` (`lua/lunette-plugins/layouts/init.luau`).
- Desktop entry id: `layouts`.
- Capability: `lunette/layouts` version 1, declared in [the layouts contract](../../../lua/lunette-contracts/layouts.luau).

## Dependencies

The provider requires no plugin capabilities and has no configuration fields. A layout contributor such as [the arc layout](../layout/arc/README.md) requires the broker and registers a named layout.

## Configuration and extension

Plugins register and apply layouts through the contract. The registration owner controls its lifetime. The shared broker guarantees, including the meaning of `continuous`, are specified in [the Lua API](../../../docs/dev/lua-api.md#bindings-menu-actions-and-layouts). The shipped consumer's tag grouping and re-arrangement policy are in [layout registration](docs/layout-registration.md).

## Tests

[Broker tests](tests/broker.luau) cover registration and application. [Inspection tests](tests/inspection.luau) cover registration metadata.