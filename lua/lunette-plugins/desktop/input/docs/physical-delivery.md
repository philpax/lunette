# Physical delivery

The `desktop/input` consumer creates one physical `lunette/focus` source. Its batch observer records each frame batch before binding and delivery handlers run, then calls `source:beginBatch` with the batch id. If the batch is already text-blocked, the source resets before handling further events.

The consumer handles keys and committed text in the frame provider's `delivery` phase. A key without an evdev code is not sent through the focus source. A command chord blocks text for the batch. The consumer also blocks text when a key result is consumed, failed, or refused. `unhandled` keys can reach later delivery handlers, unless a focus target was selected; a selected route consumes the callback even when its receiver declines the key, so the same event does not reach another delivery handler.

A physical source never inserts fallback text for a local receiver. The receiver gets physical key activations and committed text as separate operations. Native printable keys wait for committed text unless they are command chords. Native window text resolves each character through the seat's keymap. A character the layout cannot represent is refused rather than passed through `sink:typeText`.

Command chords block text, and failed or refused text blocks the rest of the batch. Disabling or unloading the consumer blocks the current batch before the source is released. This prevents a replacement source from delivering text against a route snapshot made by the previous source. The next update opens a fresh batch and restores eligibility.

The frame provider owns the translated host event and batch. [Input batches](../../../frame/docs/input-batches.md) documents that implementation. The shared contract guarantees and text invalidation limits remain in [Physical input batches](../../../../../docs/dev/input.md#physical-input-batches).

## Decisions

The physical source records the route revision before bindings run. A binding that changes focus or consumes a key must not allow later committed text from that batch to reach the new route.

A source release blocks the current batch before cleanup. Without this step, a replacement source could observe the same batch with a different route snapshot and accept text that belongs to the previous source.

## Known gaps

A batch is not correlated with an individual key. A route change, consumed binding key, or consumed or failed local key can discard unrelated text until the next update. The shared known gap and its rationale remain in [Input](../../../../../docs/dev/input.md#known-gaps).
