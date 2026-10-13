# Output scale

The scale provider creates a stateful chooser for each output. The desktop consumer measures shown window panels and applies the chooser's scale recommendation.

| Provides | Consumer requires |
| --- | --- |
| `lunette/scale` | `lunette/frame`, `lunette/panels`, `lunette/scale` |

[Provider options](config.luau) · [Contract](../../lunette-contracts/scale.luau) · [Native scale ladder](../../../docs/dev/rendering.md#the-layer-pool) · [Policy](docs/output-scale.md)
