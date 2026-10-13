# Chord dispatch

The bindings provider registers one owner-scoped callback per chord. A chord contains a LÖVR key name and an optional list of modifiers. Modifier order does not affect identity. A modifier can appear only once. The provider recognizes `control`, `alt`, `logo`, and `shift`; lock modifiers and AltGr do not participate.

A match requires exactly the named modifiers. A binding for H does not match Control-H. A matched press runs once and is consumed. A repeat is consumed without running the callback. A callback error is reported, and the press remains consumed. A binding registration ends when its owner unloads. Registering a chord already held by another registration raises.

The provider registers directly with the frame provider in its `binding` phase. A matched press therefore does not reach the physical input delivery handler. If a binding consumes a press, the frame provider blocks committed text for the rest of that batch. Later key activations still run. [Input batches](../../frame/docs/input-batches.md) describes the provider's batch handling; the shared batch guarantee is in [Input](../../../../docs/dev/input.md#physical-input-batches).

## Decisions

The bindings provider handles presses in the `binding` phase instead of dispatching from `desktop/input` to the broker. If dispatch depended on `desktop/input`, a bindings outage would stop all typing. The binding phase lets the broker consume a press before delivery without making physical typing depend on the bindings provider.

## Known gaps

The underlying application can also receive controller input while lunette is an overlay. Input blocking is not implemented. The shared limitation and specified Monado-only mechanism remain in [Input known gaps](../../../../docs/dev/input.md#known-gaps).
