# Aim and drag feedback

The adaptive filter smooths the ray used for picking, pointer coordinates, and drawing. It does not filter the controller pose, buttons, trigger, grip, or scroll, so smoothing aim does not alter grab movement or input timing.

Trigger lock holds the prior ray when an analog trigger is pulled over a live offered surface. It requires a previous sample so an initial pull cannot invent a stable hit. Movement past either unlock bound releases the lock for the rest of the pull. The release frame retains the locked position so it cannot move a click onto a neighboring surface.

The default drawing places a drag icon at the beam end using the most recently hovered panel's metres-per-pixel scale. The laser owns this drawing because it knows the pointer's seat and beam position, including when the beam is over no panel. Replacing the base `draw` callback also replaces icon drawing.

The shipped `desktop/pointing` consumer updates in the `pointing` phase and draws after overlay UI in the `feedback` phase. OpenVR bindings and haptic mapping still need SteamVR hardware validation; shared limits are in [Input](../../../../docs/dev/input.md#known-gaps).
