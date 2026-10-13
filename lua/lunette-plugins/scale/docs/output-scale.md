# Output-scale policy

A chooser selects from the native discrete scale ladder based on the nearest shown window panel for its output. It uses the nearest panel's distance from the headset position. Hidden, monitor, and dead panels do not contribute; an output with no qualifying panel keeps its current scale. If no headset position is available, the consumer makes no changes.

The chooser applies hysteresis to limit expensive toolkit relayouts near a rung boundary. Its upward and downward margins differ; the wider downward margin reduces oscillation. A jump across several rungs settles in one call. The chooser remains stateful because each output's prior rung affects the next choice.

On unload, the consumer restores an output's original scale only if the output still has the last value this consumer set. This preserves changes made by another plugin. Dead outputs are discarded.

[Scale contract](../../../lunette-contracts/scale.luau) · [Native scale ladder](../../../../docs/dev/rendering.md#the-layer-pool)
