# Tags

The tags provider stores shared named groups of panels. Owners hold memberships, exclusions, and selection overrides through owner-scoped effects. The provider accepts movable panels without requiring a panels implementation.

Plugins create tags and manage membership through [`lunette/tags`](../../lunette-contracts/tags.luau). Placement and workspace policy are defined by their consumers.

[Shared ownership and membership guarantees](../../../docs/dev/lua-api.md#tags)
