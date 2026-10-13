# Desktop input

Routes physical key presses and committed text through a physical focus source. Bindings run before delivery, but desktop typing does not require the bindings provider.

| Requires |
|---|
| [`lunette/frame`](../../frame/README.md), [`lunette/focus`](../../focus/README.md) |

The [shared input protocol](../../../lunette-contracts/docs/input.md#physical-input-batches) defines event consumption and stale-text blocking. A replacement physical-input consumer preserves those batch boundaries.
