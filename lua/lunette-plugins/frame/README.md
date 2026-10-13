# Frame provider

The frame provider dispatches LÖVR callbacks to owner-scoped handlers. It translates host key events once and opens batches for physical input. The shipped desktop entry id is `frame`.

- Module: `@lunette-plugins/frame` (`lua/lunette-plugins/frame/init.luau`)
- Provides: `lunette/frame` version 2.
- Requires: none.
- Configuration: none. The contract and phase lists in `lua/lunette-contracts/frame.luau` are the source of truth.
- Tests: [`tests/frame.luau`](tests/frame.luau), [`tests/translation.luau`](tests/translation.luau).
- Behaviour: [Input batches](docs/input-batches.md); shared input guarantees remain in [Input](../../../docs/dev/input.md#physical-input-batches) and [Frame dispatch](../../../docs/dev/lua-api.md#frame-dispatch).

The default composition and provider catalogue are in [Standard plugins](../../../docs/dev/standard-plugins.md#contracts-and-providers) and its [default configuration](../../../docs/dev/standard-plugins.md#default-configuration). Shared physical input limitations remain in [Input known gaps](../../../docs/dev/input.md#known-gaps).
