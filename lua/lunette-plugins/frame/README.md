# Frame dispatch

Dispatches LÖVR callbacks and physical-input batches. A consumed binding blocks committed text for the rest of its batch, including unrelated later text.

`frame.install { start, stop }` installs the LÖVR callbacks once, before the plugin runtime starts. The callbacks do nothing while no frame provider is active, apart from runtime startup and shutdown.

[Contract](../../lunette-contracts/frame.luau) · [Dispatch and input protocol](../../lunette-contracts/docs/input.md)
