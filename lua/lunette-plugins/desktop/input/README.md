# Desktop input

Routes physical key presses and committed text through a physical focus source. Bindings run before delivery, but desktop typing does not require the bindings provider.

| Requires |
|---|
| [`lunette/frame`](../../frame/README.md), [`lunette/focus`](../../focus/README.md) |

[Physical input batches](../../../../docs/dev/input.md#physical-input-batches) specify consumption and stale-text blocking. A custom physical-input consumer must preserve those boundaries.
