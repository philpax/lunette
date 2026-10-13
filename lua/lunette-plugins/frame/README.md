# Frame provider

Dispatches LÖVR callbacks and opens physical-input batches.

| Provides |
|---|
| [`lunette/frame`](../../lunette-contracts/frame.luau) |

The provider translates each host key event once so consumers cannot see different modifier snapshots for one press. A consumed binding blocks committed text for the rest of its batch, but unrelated text in that batch can also be discarded.
