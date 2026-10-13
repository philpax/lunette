# Pointing phases

The `desktop/pointing` consumer attaches both hands through `lunette/laser`. It gives both hands the configuration of the separate `laser` entry. Each update handler runs in the `pointing` phase and updates the laser service against the surfaces offered in that frame. Each draw handler runs in the final `feedback` phase and draws the laser beams and cursor feedback after scene and overlay drawing.

Picking runs after scene updates so it observes the current frame's surface poses. Feedback uses its own final draw phase. Raising the pointing draw handler's order would not move it after overlays because order applies only within a phase. Moving the pointing update after overlays would change interaction timing. The frame contract owns the phase list and dispatch guarantees; see [Frame dispatch](../../../../../docs/dev/lua-api.md#frame-dispatch).

## Decisions

Pointer feedback draws in the final `feedback` phase. Raising the pointing draw handler's order was insufficient because order applies only within a phase. Moving pointing updates after overlays would change interaction timing.

## Known gaps

No separate pointing-specific gap is recorded. Shared input and backend limits remain in [Input known gaps](../../../../../docs/dev/input.md#known-gaps).
