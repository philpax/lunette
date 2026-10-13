# Focus provider

The focus provider routes keyboard input to one native sink or local receiver and owns the physical and virtual input sources created through its service. The shipped desktop entry id is `focus`.

- Module: `@lunette-plugins/focus` (`lua/lunette-plugins/focus/init.luau`)
- Provides: `lunette/focus` version 2.
- Requires: `lunette/frame` version 2.
- Configuration: none. [`lua/lunette-contracts/focus.luau`](../../../lua/lunette-contracts/focus.luau) is the source of truth for targets, routes, and source operations.
- Tests: [`tests/routing-local.luau`](tests/routing-local.luau), [`tests/routing-native.luau`](tests/routing-native.luau), [`tests/physical.luau`](tests/physical.luau).
- Behaviour: [Routing and delivery](docs/routing.md); shared route and native seat guarantees remain in [Input](../../../docs/dev/input.md#keyboard-routing).

The provider catalogue and default composition are in [Standard plugins](../../../docs/dev/standard-plugins.md#contracts-and-providers) and its [default configuration](../../../docs/dev/standard-plugins.md#default-configuration). Virtual translation, physical input gaps, and multi-seat limits remain in [Input known gaps](../../../docs/dev/input.md#known-gaps).
