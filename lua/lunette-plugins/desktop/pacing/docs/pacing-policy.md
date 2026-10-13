# Pacing policy

`desktop/pacing` reads shown panels in the `overlay` update phase and applies the resource-free pacer supplied by `lunette/pacing` to each window. It passes the window's `contentType`, whether the panel is hidden, and whether the window's `commit` changed. The native mechanism is `window:setFrameRate`; its 1 Hz floor is specified in [Rendering](../../../../../docs/dev/rendering.md#frame-pacing).

## Commit observations

The consumer observes commit changes only while the window is unthrottled. A throttled client's commits describe the throttle, so the consumer does not use them as evidence of activity. The pacer is kept per window. If the panel is removed from the registry, the consumer resets its window to unthrottled operation. Unloading the entry does the same for every window it paced.

With the default tuning, a hidden panel's window runs at 1 Hz. A hidden video, game, or busy window runs at 30 Hz. A shown panel's window is unthrottled. Content type and recent commit rate determine exemptions in the pacing provider; see [Frame pacing and output scale](../../../../../docs/dev/lua-api.md#frame-pacing-and-output-scale).

## Monitor capture

When `pauseMonitors` is true, a hidden monitor panel's capture is paused. A shown monitor panel resumes if this consumer paused it. If a monitor panel disappears, the consumer resumes its capture. Unloading the entry resumes each capture it paused. The setting is defined in [`config.luau`](../config.luau) and defaults to true.

## Decisions

Pacing is a provider and a separate desktop consumer. A different rate policy is a different provider, and a different reading of the scene is a different consumer. The desktop entry reads the scene and applies the provider's answer. The default entry is on and reverts its changes on unload, because a disabled entry must not leave outputs at a step it chose. The shared provider/consumer boundary is recorded in [Standard plugins](../../../../../docs/dev/standard-plugins.md#pacing-and-scale).

## Deliberately left open

The consumer reads whether a panel is hidden. It does not account for view direction, gaze, or distance. Pacing by view direction risks a stutter as the head turns back. The choice remains open until it can be tried on hardware. The shared question remains in [Standard plugins](../../../../../docs/dev/standard-plugins.md#pacing-and-scale).
