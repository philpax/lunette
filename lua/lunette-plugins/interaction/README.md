# Interaction provider

The interaction provider turns pointer samples into surface hits, pointer events, native sink input, and spatial grabs. The shipped desktop entry id is `interaction`.

- Module: `@lunette-plugins/interaction` (`lua/lunette-plugins/interaction/init.luau`)
- Provides: `lunette/interaction` version 2.
- Requires: `lunette/drops` version 1 and `lunette/focus` version 2.
- Configuration: `tuning`, `focusOnPress`, `drive`, and `constrain`. [`config.luau`](config.luau) is the source of truth for defaults and types. The `drive` and `constrain` callbacks wrap their default implementations.
- Per-pointer options: `seat`, `tuning`, and optional `vibrate`, as declared by [`lua/lunette-contracts/interaction.luau`](../../../lua/lunette-contracts/interaction.luau).
- Tests: [`tests/lifecycle.luau`](tests/lifecycle.luau), [`tests/pointers.luau`](tests/pointers.luau), [`tests/protocol.luau`](tests/protocol.luau).
- Shared pointer event and cancellation guarantees: [Input](../../../docs/dev/input.md#surface-pointer-input). Grab behavior and tuning: [Grabs](docs/grabs.md).

The provider emits `lunette/drops` when a grab ends. The provider catalogue and default composition are in [Standard plugins](../../../docs/dev/standard-plugins.md#contracts-and-providers) and its [default configuration](../../../docs/dev/standard-plugins.md#default-configuration). The drop broker and native drag semantics are described in [Pointers and drops](../../../docs/dev/lua-api.md#pointers-and-drops) and [Input](../../../docs/dev/input.md#drag-and-drop).
