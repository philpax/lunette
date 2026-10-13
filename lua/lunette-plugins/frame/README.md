# Frame provider

Dispatches LÖVR callbacks and opens physical-input batches.

| Provides |
|---|
| [`lunette/frame`](../../lunette-contracts/frame.luau) |

The shared [input protocol](../../lunette-contracts/docs/input.md#frame-dispatch) defines phase ordering, event consumption, protected handler errors, and input-batch guarantees. The provider translates each host key event once so consumers see one consistent modifier snapshot. A consumed binding blocks committed text for the rest of its batch, though unrelated later text in that batch can also be discarded.

`frame.install { start, stop }` assigns the LÖVR callbacks once, before the plugin runtime exists: `lovr.load` creates the runtime, and `lovr.quit` closes it. Installing from the provider's effect and restoring previous callbacks on unload was rejected because correct restoration would require reverse unload order, which instance reload and multiple runtimes do not guarantee. `lovr.load` calls `start`; the other callbacks reach the loaded frame activation and do nothing when none is loaded. `lovr.quit` calls `stop` after quit handlers under a protected call.
