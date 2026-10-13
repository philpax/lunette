# Frame pacing

The pacing provider creates a resource-free pacer for each caller. The separate `desktop/pacing` consumer reads window panels and applies the selected frame rate.

## Entry

- Module: `@lunette-plugins/pacing` (`lua/lunette-plugins/pacing/init.luau`).
- Desktop entry id: `pacing`.
- Capability: `lunette/pacing` version 1, declared in [the pacing contract](../../../lua/lunette-contracts/pacing.luau).
- Shipped consumer: `@lunette-plugins/desktop/pacing`, entry id `desktop/pacing`.

## Dependencies

The provider requires no plugin capabilities. The shipped consumer requires `lunette/frame`, `lunette/panels`, and `lunette/pacing`.

## Configuration and extension

The provider schema in [config.luau](config.luau) defines the pacing `tuning`. The consumer schema in [desktop/pacing/config.luau](../desktop/pacing/config.luau) defines `pauseMonitors`. [Pacing policy](docs/pacing-policy.md) specifies how the provider and consumer divide selection from application. [Standard plugins](../../../docs/dev/standard-plugins.md#pacing-and-scale) summarizes the default entries. The native frame-rate floor and compositor mechanisms remain in [Rendering](../../../docs/dev/rendering.md#frame-pacing).

## Tests

[Pacer tests](tests/pacer.luau) cover visibility, content hints, commit history, and unobserved frames. [Desktop pacing tests](../desktop/pacing/tests/pacing.luau) cover application and restoration.