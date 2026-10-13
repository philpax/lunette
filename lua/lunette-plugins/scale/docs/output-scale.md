# Output scale

The scale provider hands out a chooser per output. `desktop/scale` measures the scene and applies the chooser's answer to the output. The scale contract is specified in [scale.luau](../../../lunette-contracts/scale.luau); the native ladder is defined with the layer pool in [Rendering](../../../../docs/dev/rendering.md#the-layer-pool).

## Chooser

A chooser returns a rung of `lunette.scaleSteps()` from the distance to the nearest panel showing the output's clients, and moves between rungs with hysteresis, because some toolkits re-lay out expensively on each scale change. The ladder is the one the layer pool quantises to ([Rendering](../../../../docs/dev/rendering.md#the-layer-pool)).

For a measured distance, the chooser computes an ideal scale as `reference / max(distance, nearest)`. The initial choice is the largest rung no greater than the ideal. If every rung exceeds the ideal, the first rung is selected. A distance below `nearest` uses `nearest` as its denominator.

After the first choice, the chooser applies hysteresis. It steps up when the ideal reaches the next rung multiplied by `1 + raise`. It steps down when the ideal falls to or below the current rung multiplied by `1 - lower`. The default `raise` is 0.06 and `lower` is 0.12. These margins differ because the wider lower margin reduces oscillation near a rung. A jump across multiple rungs settles in one call rather than rendering at every intermediate rung.

The schema in [config.luau](../config.luau) owns the defaults: `reference = 1`, `raise = 0.06`, `lower = 0.12`, and `nearest = 0.05`. `reference` and `nearest` must be positive; `raise` must be non-negative; `lower` must be non-negative and below 1.

## Desktop application and cleanup

`desktop/scale` measures from the head to the centre of every shown window panel, takes the nearest for each `window.output`, and sets the output's scale when its chooser's step changes. An output with no shown window panel keeps its scale, and nothing changes while the headset reports no head.

The consumer considers shown window panels only. Hidden panels, monitor panels, and dead panels contribute no distance. For each output, it chooses the nearest panel centre to the headset head position and uses that distance for the output's chooser. An output with no shown window panel keeps its current scale. If the headset reports no head, the consumer makes no changes.

`desktop/scale` unloads by restoring what it set. A scale is restored only if it is still the one the entry set. The consumer records an output's original scale when it first changes that output. On unload, it restores the original scale only if the output still has the value last applied by this consumer. If another plugin changed the scale, cleanup preserves that change. Outputs that are dead are discarded.

Scale is a rung from the same discrete ladder the layer pool uses, because discrete sizes avoid reallocating clients for continuous distance changes. A chooser is stateful because hysteresis belongs to one output over time.

## Decisions

The scale provider returns a chooser, and `desktop/scale` reads the scene and applies it. The shared decision to separate chooser policy from scene reading remains in [the Lua API](../../../../docs/dev/lua-api.md#pacing-and-scale-hand-out-choosers). Pacing and scale's shared provider and consumer decision is recorded in [Pacing policy](../../pacing/docs/pacing-policy.md#decisions).

The nearest shown window panel for each output supplies distance. Hidden panels and monitor panels do not select scale. Outputs without a qualifying panel keep their scale rather than receiving a default inferred from another output.

Hysteresis limits repeated relayout near a rung boundary. Some toolkits re-lay out expensively on each scale change, so rising and falling use separate margins. The lower margin is wider than the raise margin.

## Known gaps

The selection policy does not consider view direction, gaze, or panel visibility beyond the hidden flag. Shared scale-ladder and layer-pool guarantees remain in [Rendering](../../../../docs/dev/rendering.md#the-layer-pool).