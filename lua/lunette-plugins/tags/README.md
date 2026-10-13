# Tags

The tags provider stores shared named groups of panels. Owners hold memberships, exclusions, and selection overrides through effects; the provider has no dependency on the panels provider.

## Entry

- Module: `@lunette-plugins/tags` (`lua/lunette-plugins/tags/init.luau`).
- Desktop entry id: `tags`.
- Capability: `lunette/tags` version 1, declared in [the tags contract](../../../lua/lunette-contracts/tags.luau).

## Dependencies

The provider requires no plugin capabilities and has no configuration fields. The `lunette/tags` contract accepts movable panels without requiring a panel implementation.

## Configuration and extension

There are no provider settings. The shipped provider and placement connections are listed in [standard plugins](../../../docs/dev/standard-plugins.md#placement). Plugins create and hold tags and register change listeners through the contract. Its shared ownership, membership, exclusion, selection, and notification guarantees remain in [the Lua API](../../../docs/dev/lua-api.md#tags). Placement and workspace policy are documented by their respective consumers.

## Tests

[Tag tests](tests/tags.luau) cover owner-scoped selection and membership, shared holds, exclusions, and change notifications.