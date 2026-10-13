# Layout registration

The `layouts` provider is a broker for named layout implementations. A plugin contributes an implementation by registering a name and an `apply` callback through the `lunette/layouts` contract. The broker invokes that callback only when a consumer applies the name. A layout receives the live panels and their caller-supplied order; it owns no panels, tags, or scene-reading policy.

The optional `continuous` flag tells a consumer that it may apply the layout every frame. The broker does not schedule continuous layouts. The shipped `desktop/arrange` consumer selects and applies a configured layout; its policy is documented by the separately maintained [desktop arrangement entry](../../desktop/arrange/README.md).

The shared registration lifetime, unique-name, notification, inspection, and application guarantees remain in [the Lua API](../../../../docs/dev/lua-api.md#bindings-menu-actions-and-layouts) and [layouts.luau](../../../../lua/lunette-contracts/layouts.luau). The contract is the source of truth for the method shapes. The provider has no configuration schema.

## Decisions

The broker shape and the rejected per-layout contract remain documented in [the Lua API](../../../../docs/dev/lua-api.md#layouts-are-a-broker). A layout's options come from its registering plugin. `desktop/arrange`'s use of one configured layout across its tags is owned by the [desktop arrangement entry](../../desktop/arrange/README.md).

## Known gaps

The arc is the only shipped layout. [examples/layout](../../../../examples/layout/) holds grid and follow layouts as examples.
