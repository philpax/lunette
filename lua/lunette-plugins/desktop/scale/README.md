# Output scale

Chooses output scale from the nearest shown window panel. Outputs without a shown window panel keep their current scale.

| Requires |
| --- |
| `lunette/frame`, `lunette/panels`, and `lunette/scale` |

On unload, the consumer restores an output's original scale only if no other plugin has changed the value since. The [scale provider](../../scale/README.md) controls density, scale steps, and hysteresis.
