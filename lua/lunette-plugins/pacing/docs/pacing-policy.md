# Pacing policy

The pacing provider hands out pure, resource-free pacers. `desktop/pacing` reads the scene and applies their answers through `window:setFrameRate`. The native layer's callback throttling and 1 Hz floor remain specified in [Rendering](../../../../docs/dev/rendering.md#frame-pacing); the service contract remains in [pacing.luau](../../../lunette-contracts/pacing.luau).

## Pacer decisions

A pacer leaves a visible window unthrottled. It runs a hidden window at the `exempt` rate when the window's content type is exempt or at least the `busy` fraction of recent samples drew, and at the `background` rate otherwise. The hint covers a paused video; the commit rate covers a player that sets no hint.

The default tuning is `background = 1` Hz, `exempt = 30` Hz, `history = 90` observations, `busy = 0.5`, with `video` and `game` exempt by content type and `none` and `photo` not exempt. These values and their validation are owned by [config.luau](../config.luau). The default consumer therefore runs a hidden quiet window at 1 Hz, a hidden video or game at 30 Hz, and a shown window unthrottled.

The content-type hint handles paused video, which would otherwise have no recent commits. Commit history handles clients that do not set the hint. An empty history is not evidence that a new client is idle; until a window has observations, the commit-based busy test is false, but an exempt content-type hint still exempts it.

An observation without `drew` does not enter the history. The consumer observes commits only while a window is unthrottled, because a throttled client's commits describe the throttle. Recording those frames as quiet would eventually classify a busy client as idle. The rolling history counts only observations that the consumer can judge. `busy` is inclusive at its boundary.

## Desktop application and cleanup

`desktop/pacing` passes each window panel's hidden state, the window's `contentType`, and whether its `commit` changed to a pacer kept for the window. It observes commits only while the window is unthrottled, because a throttled client's commits describe the throttle. With the default tuning, a hidden panel's window runs at 1 Hz, a hidden video, game, or busy window at 30 Hz, and a shown panel's window unthrottled. A window whose panel is removed returns to unthrottled. While `pauseMonitors` is true, a hidden monitor panel's capture is paused.

The consumer keeps one pacer per window, applies a rate only when it changes, and releases it when the panel disappears. A shown monitor panel resumes a paused capture. A monitor no longer represented by a live panel also resumes. The consumer restores rates and monitor capture when it unloads. The schema in [desktop/pacing/config.luau](../../desktop/pacing/config.luau) owns `pauseMonitors`; it defaults to true.

The native layer also uses damage-driven layer copies and can skip lunette's scene. Those mechanisms do not replace per-window frame callback policy. [Rendering](../../../../docs/dev/rendering.md#frame-pacing) specifies the native mechanisms.

## Decisions

Pacing and scale are providers (issue #38), and the desktop entries read the scene and apply them. A different rule is a different provider, and a different reading of the scene is a different consumer. Both entries are on by default and revert on unload, because a disabled entry must not leave outputs at a step it chose.

Pacing and scale are providers (issue #38), and the desktop entries read the scene and apply them. A different rule is a different provider, and a different reading of the scene is a different consumer. Both entries are on by default and revert on unload, because a disabled entry must not leave outputs at a step it chose. The shared chooser contract remains specified in [the Lua API](../../../../docs/dev/lua-api.md#pacing-and-scale-hand-out-choosers).

## Known gaps

The native layer enforces a minimum frame rate of 1 Hz because clients that receive no frame callbacks often stop processing input as well. Hardware acceptance for view-based pacing remains deliberately open.

## Deliberately left open

Pacing reads whether a panel is hidden, not whether it is in view, gazed at, or distant ([Rendering](../../../../docs/dev/rendering.md#frame-pacing)). Pacing by view direction risks a stutter as the head turns back, and the choice is left until it can be tried on hardware.