# Drops provider

The drops provider notifies consumers when a surface grab ends. The interaction provider emits the notification before it clears the pointer's carried surface. The shipped desktop entry id is `drops`.

- Module: `@lunette-plugins/drops` (`lua/lunette-plugins/drops/init.luau`)
- Provides: `lunette/drops` version 1.
- Requires: none.
- Configuration: none. [`lua/lunette-contracts/drops.luau`](../../../lua/lunette-contracts/drops.luau) is the source of truth for the drop payload and service methods.
- Tests: [`interaction/tests/lifecycle.luau`](../interaction/tests/lifecycle.luau).
- Shared pointer and drag guarantees: [Input](../../../docs/dev/input.md#surface-pointer-input) and [Pointers and drops](../../../docs/dev/lua-api.md#pointers-and-drops).

The contract has no history: a drop is a transient notification. The provider catalogue and default composition are in [Standard plugins](../../../docs/dev/standard-plugins.md#contracts-and-providers) and its [default configuration](../../../docs/dev/standard-plugins.md#default-configuration). Shared host drag-and-drop limitations remain in [Input known gaps](../../../docs/dev/input.md#known-gaps).
