# Bindings provider

Matches host key presses before physical delivery.

| Provides | Requires |
|---|---|
| [`lunette/bindings`](../../lunette-contracts/bindings.luau) | [`lunette/frame`](../frame/README.md) |

A chord matches only the exact listed modifiers; a match consumes the press and blocks committed text for that batch. Modifier order does not affect matching. Lock modifiers and AltGr do not participate. Dispatch runs before physical delivery, so a bindings outage does not disable typing.
