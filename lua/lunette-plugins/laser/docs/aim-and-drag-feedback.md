# Aim and drag feedback

The laser provider filters each hand's ray before it reaches pointer picking and drawing. The default filter is enabled. It normalizes the input direction and applies an adaptive low-pass filter to origin and direction. `minCutoff` defaults to 2 Hz, `derivativeCutoff` to 5 Hz, `angularBeta` to 4, and `positionBeta` to 40. The beta values scale the cutoff by unit-direction speed and positional speed in metres per second. `resetAfter` defaults to 0.2 seconds. The filter history resets when input is unavailable, the direction is zero, the frame has no positive time step, or the time gap exceeds `resetAfter`.

The filtered ray is used for picking, delivered pointer coordinates, and the drawn beam. The hand pose, button states, trigger, grip, and scroll remain from the unfiltered input sample. Grab movement therefore follows the controller pose without aim filtering.

The trigger lock holds the prior filtered ray while the analog trigger is pulled over an offered surface. The threshold defaults to 0.1. The lock starts only if there is a prior sample, a prior raw aim, and a live hovered surface. Movement greater than `unlockAngle` or `unlockDistance` releases the lock for the rest of the pull. The default angle is pi/60 radians and the default distance is 0.03 m. The lock also releases for grip, an active grab, a zero ray, a time gap greater than `aim.resetAfter`, tracking loss, or a surface that is no longer offered. A reader without analog trigger pressure never locks. The frame that releases the lock keeps the locked position, so releasing does not move a click onto a neighbouring surface.

When the laser's seat carries a drag with an icon texture, the default drawing places the icon at the beam end, facing the hand. The client's icon offset positions the top-left corner relative to the pointer. The icon uses the metres-per-surface-pixel scale of the last hovered panel. Before any panel hover, the fallback scale is 0.001 m per pixel, equivalent to a thousand-pixel window one metre wide. The last scale remains while the beam is not over a panel.

The icon uses the drag's source crop and the same opaque or premultiplied-pixel conversion shaders as client surfaces. It draws as an overlay, like the beam. Its mesh is rebuilt when the crop changes and released when the laser is destroyed. The `draw` hook wraps the default drawing; replacing the base draw also replaces icon drawing.

The `laser` entry is a provider. The shipped `desktop/pointing` consumer updates both hands in the `pointing` phase and draws them in the `feedback` phase, after overlay UI. A different consumer can call `attach`, `update`, and `draw` through `lunette/laser`.

## Decisions

The adaptive filter applies only to the ray used for picking, pointer coordinates, and drawing. The grab pose, buttons, and scroll remain unfiltered so smoothing aim does not change controller-relative movement or input timing.

Trigger lock holds the prior ray only when the trigger first crosses its threshold over a live offered surface. Requiring a previous sample and raw aim prevents an initial pull from inventing a stable hit. Movement beyond either unlock bound resumes aiming for the rest of the pull. The release frame retains the locked ray so the release cannot activate a neighbouring surface.

The drag icon follows the beam end and uses the most recently hovered panel's metres-per-pixel scale. The remembered scale keeps the icon consistent with the source window while the beam crosses empty space. The fallback is 0.001 m per pixel before any panel provides a scale.

The laser draws the icon because it owns the seat and knows where its pointer lands in the scene. The panels provider was rejected because it does not know which seat points at a panel or where the beam ends off every panel. The icon faces the hand rather than lying on the hovered panel, as WayVR's faces the head, so it stays readable over a curved panel and over nothing.

## Known gaps

OpenVR controller bindings and haptic frequency mapping need SteamVR hardware validation. Shared backend limitations remain in [Input known gaps](../../../../docs/dev/input.md#known-gaps).
