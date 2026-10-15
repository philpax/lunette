# Registration

Registration provides listener delivery and named-value storage for callers with a plugin context. It has no plugin leaves, activation entry, or runtime services.

- [Listeners](listeners.luau), `@lunette-plugins/registration/listeners`, snapshots registrations at dispatch start and calls only listeners with live owners. Reported callback failures do not stop later listeners.
- [Registry](registry.luau), `@lunette-plugins/registration/registry`, rejects duplicate names and lists live registrations in registration order.

Each collection belongs to its caller. Registration takes an explicit owner and attaches its inverse through the supplied context. Disposal removes registrations; no global collection outlives the context. Metadata inspection invokes no callbacks and grants no authority. The [ownership contract](../../lunette-plugin/ownership.md) defines acquisition and disposal, and the [inspection contract](../../lunette-contracts/inspection.luau) defines metadata. [Shipped plugins](../README.md) defines public imports.
