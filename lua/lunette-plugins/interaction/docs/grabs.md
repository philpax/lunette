# Grabs

The interaction provider picks the nearest live offered surface within the configured `reach`. It normalizes the ray before calling each surface's `raycast`. The default reach is 8. Scroll applies a dead zone, scales by frame time, and reverses the vertical axis so an upward stick deflection scrolls up.

A grip begins a grab on a hit surface unless `grabbable` is false. A surface can opt into trigger-grab with `triggerGrabbable`; a new primary-button press then begins the grab. A surface can redirect either grab to another offered surface through `grabTarget`. Starting a grab cancels Lua pointer captures before moving the surface. Native pressed sinks still receive their releases. A held trigger cannot start a new gesture after grab cancellation until it is released and pressed again.

The grab records the surface pose relative to the controller pose. The panel therefore keeps its pose relative to the controller while the controller moves. The grab can use thumbstick deflection to push the panel along its local reach axis, with a scroll dead zone and reach limits. The default `grabDeadZone` is 0.006, `scrollDeadZone` is 0.2, `reachScale` is 1.2, `reachMinimum` is 0.2, and `reachMaximum` is 6. The `scrollScale` is 900.

A second pointer can grab the same surface to scale it. The provider records the initial separation and width, then scales width in proportion to the separation change. The result is clamped to `resizeMinimum` and `resizeMaximum`, which default to 0.15 and 4. If the second pointer stops grabbing, the remaining pointer continues with an ordinary grab offset.

A grab emits one `lunette/drops` notification before it clears the carried surface. The listener can inspect `pointer.grabbed` during that notification. The notification happens for a normal grab end and when the pointer detaches the grab during cleanup. Shared cancellation reasons and capture behavior remain in [Input](../../../../docs/dev/input.md#surface-pointer-input).

## Decisions

A grab keeps the panel's pose relative to the controller. Upright-only movement was rejected after headset testing found it less usable.

## Known gaps

Input delivered to an overlay can also reach the underlying application. Input blocking remains unimplemented, as recorded in [Input known gaps](../../../../docs/dev/input.md#known-gaps).
