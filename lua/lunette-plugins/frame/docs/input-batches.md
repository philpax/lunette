# Input batches

The frame provider opens an input batch before each update's handlers. The first key or text callback also opens a batch when no batch is open. Key and text callbacks until the next update share the batch identifier. Batch identifiers increase within one provider activation and do not continue across replacements. The `lunette/frame` schema 2 contract owns the batch fields and observer API.

The provider translates each host key event once. It maps LÖVR key names to evdev codes and resolves held modifiers from the host snapshot when present, or from currently held keys otherwise. A key without a mapped evdev name has no code. The contract event retains the LÖVR key name and scancode as well. The text event carries committed text, its first code point, and modifiers held at that callback. `translation.luau` is the source of truth for this map.

Right Alt maps to `mod5`, which is distinct from command Alt. When a host snapshot reports Alt, the provider polls the sided Alt keys to distinguish left Alt from right Alt. The snapshot uses `logo` for LÖVR's `super`. The shared `keys` contract owns the modifier names and physical snapshot shape.

The bindings provider handles key events in the `binding` phase, before delivery. A binding that consumes a key causes the frame provider to republish the current batch with `textBlocked=true`. The provider also exposes `blockText(batchId)`, which returns false if the identifier is not current. Blocking text does not suppress later key events.

## Decisions

The frame provider translates each key event once, in the provider that owns `lovr.keypressed`. Translating in each consumer was rejected because a consumer that polls held keys and one that reads the host snapshot can see one press with two modifier sets. A chord could then match a binding that the window receives differently. The key map and modifier translation are LÖVR-specific, so they live with the frame provider rather than in `@lunette-contracts/keys`. The shared contract keeps only the runtime's codes, the modifier each modifier key holds, the host snapshot type, and which modifiers make a command chord.

## Known gaps

Batches are bounded by updates, not correlated per key. A consumed binding can therefore invalidate unrelated committed text in the same batch. The shared physical text limits are in [Input known gaps](../../../../docs/dev/input.md#known-gaps).
