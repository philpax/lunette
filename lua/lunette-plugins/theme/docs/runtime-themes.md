# Runtime theme implementation

The runtime theme provider implements the [`lunette/theme` contract](../../../lunette-contracts/theme.luau). The contract owns selection order, snapshot revisions, notification semantics, consumer appearance precedence, and capture behavior; [Runtime themes in the Lua API](../../../../docs/dev/lua-api.md#runtime-themes) specifies those guarantees. The provider implementation is in [`init.luau`](../init.luau).

## Selection preparation

The provider parses an override set and resolves it against the base theme before registering a selection. It obtains the resolved font face before the selection enters the live list. A malformed override or font-load failure therefore changes no provider state.

The provider registers a selection through deferred owner acquisition. This prevents queued lifecycle work from running between selection registration and publication. The explicit `dispose` method defers change delivery until the owner-scoped effect finishes its inverse, because the runtime revokes owner authority while that inverse runs.

The live selection list retains registration order. The provider scans it from newest to oldest and uses the first live selection as the effective theme. Disposing that registration removes it from the list. The provider publishes only when descriptor equality shows that the effective theme changed.

## Font cache

The provider keys its face cache by the font descriptor. A default font uses `lovr.graphics.getDefaultFont`; a file font uses `lovr.graphics.newFont` with the specified file, size, and spread. The provider does not release faces explicitly. Recorded passes hold references to faces, so explicit release could invalidate a face still in use. Provider shutdown clears the cache and lets LÖVR release faces through garbage collection.

## Catalog boundary

The separate [`themes` provider](../../themes/README.md) brokers owner-scoped named complete themes and selects nothing. The standard and Arcade consumers register choices. The desktop selector chooses a catalog entry and applies it through this provider. The shipped connections are summarized in [the shipped plugin catalogue](../../../../docs/dev/standard-plugins.md#contracts-and-providers).

## Decisions

The catalog and runtime selection remain separate services. The catalog stores named choices, while `lunette/theme` resolves the effective appearance. This lets configurations disable or replace catalog entries without changing consumers that read the runtime theme.

The provider uses deferred registration and waits until an effect inverse returns before delivering a disposal-triggered change. These measures keep queued lifecycle work and revoked owner authority from interleaving with selection publication. Notification ordering and consumer refresh guarantees remain in the [`lunette/theme` contract](../../../../docs/dev/lua-api.md#runtime-themes).

## Known gaps

Geometry recorders do not rasterise edges, alpha, depth, or fonts. The shared [rendering specification](../../../../docs/dev/rendering.md#known-gaps) records the scope of graphics checks and the remaining manual headset acceptance.
