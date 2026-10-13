# Adoption

The adoption provider connects eligible compositor windows to placement. The desktop consumer supplies default tags, an optional filter, and pose memory.

| Provides | Requires |
| --- | --- |
| `lunette/adoption` | `lunette/panels`, `lunette/placement`, `lunette/rules` |

[Consumer options](../desktop/adoption/config.luau) · [Contract](../../lunette-contracts/adoption.luau) · [Placement](../placement/README.md)

## Eligibility and placement

The filter runs before rule resolution. A resolved `adopt = false` excludes a window; otherwise resolved properties and defaults go to placement. Ending the start removes its placements but does not close windows.

## Pose memory

The optional pose-memory child registers a native-precedence `lunette.pose` rule source before adoption starts. It saves each dropped panel pose, which then overrides the saved arrangement. The child must start before the first window resolves. It requires the drops, panels, and rules services; a replacement interaction provider must emit drops through that contract.

Pose memory stays together because writing a dropped pose without registering its reader loses hand-placed poses after reload. [Arrangement](../arrangement/docs/persistence.md) describes saved-state matching and precedence.