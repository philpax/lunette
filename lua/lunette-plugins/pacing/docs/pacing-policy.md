# Pacing policy

The provider creates a resource-free pacer. The desktop consumer reads window visibility and applies the recommendation with `window:setFrameRate`. The native callback throttling and minimum rate are specified in [Rendering](../../../../docs/dev/rendering.md#frame-pacing).

Visible windows remain unthrottled. Hidden windows use a lower rate unless recent unthrottled commits show activity or a content-type hint marks video or games as exempt. The hint keeps paused video responsive; commit history covers clients that omit it. An empty history does not prove that a new client is idle, but without an exempt hint it does not satisfy the busy test.

The consumer observes commits only while a window is unthrottled. Throttled commits reflect the consumer's own rate and would make a busy client appear idle. It keeps a pacer per window and applies changes only when the rate changes.

When a panel disappears, its window returns to unthrottled operation. Hidden monitor capture can pause; it resumes when the panel is shown or no live panel represents that monitor. The consumer restores rates and capture when it unloads, so disabling it does not leave outputs at rates it selected.

Pacing uses hidden state rather than view direction or gaze. View-based pacing remains pending headset acceptance because turning back toward a throttled window could cause stutter.

[Pacing contract](../../../lunette-contracts/pacing.luau) · [Consumer options](../../desktop/pacing/config.luau)
