# Bindings provider

The bindings provider matches host key presses against owner-scoped chords before delivery handlers run. The shipped desktop entry id is `bindings`.

- Module: `@lunette-plugins/bindings` (`lua/lunette-plugins/bindings/init.luau`)
- Provides: `lunette/bindings` version 1.
- Requires: `lunette/frame` version 2.
- Configuration: none. The chord and registration types in [`lua/lunette-contracts/bindings.luau`](../../../lua/lunette-contracts/bindings.luau) define the public surface.
- Tests: [`tests/broker.luau`](tests/broker.luau).
- Behaviour and rationale: [Chord dispatch](docs/chord-dispatch.md); shared key event ordering remains in [Frame dispatch](../../../docs/dev/lua-api.md#frame-dispatch).

The provider catalogue and default composition are in [Standard plugins](../../../docs/dev/standard-plugins.md#contracts-and-providers) and its [default configuration](../../../docs/dev/standard-plugins.md#default-configuration). A binding cannot suppress an input that already reached the underlying application. The shared input-blocking status is in [Input known gaps](../../../docs/dev/input.md#known-gaps).
