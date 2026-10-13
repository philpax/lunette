# Menu actions broker

The menu provider stores owner-scoped actions and invokes callbacks. It renders no menu; the wrist-menu consumer is a separate entry.

Plugins register actions through [`lunette/menu`](../../lunette-contracts/menu.luau). Listing reads explicit enabled and selected state and does not run action code. Consumers update that state through the broker.

[Shared broker guarantees](../../../lua/lunette-contracts/policy-services.md#brokers)
