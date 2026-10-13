# Placement composition

Placement joins rules, panels, and tags. The shipped desktop composes workspaces, configured rules, persistence, layout selection, and adoption as separate entries, so each policy can be replaced independently. A custom rule source that must affect initial adoption registers before `desktop/adoption`.

Rule sources resolve by ascending precedence and then registration order. Rules within each source apply in list order; later values replace earlier ones. Request defaults fill only unset properties. Placement returns a frozen merged property set with the panel. The configurable `panelOptions` callback maps those properties to panel creation; other resolved properties remain available to consumers.

Placement owns the panel, tag holds, memberships, and hidden override for the placement lifetime. Removing the panel ends the placement. Invalid encoded poses are reported and ignored. Tags named by resolved properties are held and created when needed.

The provider announces placements with their resolved properties. This lets layout and other consumers handle manually placed windows like adopted windows. The provider keeps no resolved-property provenance in inspection snapshots.

[Shared lifecycle guarantees](../../../../docs/dev/lua-api.md#rules-and-placement) · [Placement contract](../../../../lua/lunette-contracts/placement.luau)
