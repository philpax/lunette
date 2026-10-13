# Adoption

Connects eligible compositor windows to placement. The [desktop consumer](../desktop/adoption/README.md) supplies default tags, filtering, and optional pose memory.

The filter runs before rules; resolved `adopt = false` excludes a window. Stopping adoption removes its placements without closing windows.

[Contract](../../lunette-contracts/adoption.luau) · [Placement precedence](../../../docs/development/standard-plugins.md#placement)
