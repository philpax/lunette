# Output scale

The scale provider creates a stateful chooser for each caller. The separate `desktop/scale` consumer finds shown window panels and applies the chooser's output scale.

## Entry

- Module: `@lunette-plugins/scale` (`lua/lunette-plugins/scale/init.luau`).
- Desktop entry id: `scale`.
- Capability: `lunette/scale` version 1, declared in [the scale contract](../../../lua/lunette-contracts/scale.luau).
- Shipped consumer: `@lunette-plugins/desktop/scale`, entry id `desktop/scale`.

## Dependencies

The provider requires no plugin capabilities. The shipped consumer requires `lunette/frame`, `lunette/panels`, and `lunette/scale`. Neither entry has an optional child.

## Configuration and extension

The provider schema in [config.luau](config.luau) defines chooser tuning. The shipped consumer has no settings. [Output-scale policy](docs/output-scale.md) specifies distance selection, scale rungs, and hysteresis. [Standard plugins](../../../docs/dev/standard-plugins.md#pacing-and-scale) summarizes the default entries. [Rendering](../../../docs/dev/rendering.md#the-layer-pool) defines the native scale ladder and layer-pool mechanism.

## Tests

[Chooser tests](tests/chooser.luau) cover clamping, hysteresis, large jumps, and monotonic walks. [Desktop scale tests](../desktop/scale/tests/scale.luau) cover per-output selection and conditional restoration.