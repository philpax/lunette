# Frame dispatch

Dispatches LÖVR callbacks and physical-input batches. A consumed binding blocks committed text for the rest of its batch, including unrelated later text.

`frame.install { start, stop }` installs the LÖVR callbacks once, before the plugin runtime starts. The callbacks do nothing while no frame provider is active, apart from runtime startup and shutdown.

Draw handlers record the main Pass and may return preparatory passes in a plain dense array. The host submits those passes in handler order and then array order, before the main headset and desktop-window passes, in the same submission. Plugins do not submit passes or wait for graphics work. Nil and empty arrays add no preparatory passes. `lovr.draw` keeps its first result false and returns the collected passes as its second result, or nil when none exist.

The [frame contract](../../../lunette-contracts/frame.luau) defines the draw result. Results contain only distinct Pass objects and exclude the main Pass, including duplicates across handlers. An invalid result is reported at the handler boundary and contributes no passes; later handlers still run. Collection ends with each draw invocation and never carries work across frames or provider replacement.

The caller keeps every returned Pass and its graphics resources valid until submission. Pass objects have no public headset-session validity query. The provider checks the public object type, not session validity, and callers do not reuse passes from an invalidated session or release them before submission.

[Contract](../../../lunette-contracts/frame.luau) · [Dispatch and input protocol](../../../lunette-contracts/docs/input.md)
