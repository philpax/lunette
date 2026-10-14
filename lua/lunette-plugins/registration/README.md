# Registration

Registration provides listener delivery and named-value storage for callers with a plugin context. The category has no plugin leaves, activation entry, or runtime services.

## Public libraries

- [Listeners](listeners.luau), `@lunette-plugins/registration/listeners`, snapshots registrations at dispatch start and calls only listeners with live owners. Callback failures are reported without stopping later listeners.
- [Registry](registry.luau), `@lunette-plugins/registration/registry`, rejects duplicate names and lists live registrations in registration order.

Each collection belongs to the caller that creates it. Registration takes an explicit owner and attaches its inverse through the supplied context. Owner disposal removes the registration; no global collection outlives the context. Metadata inspection does not invoke registered callbacks or grant authority. The [ownership contract](../../lunette-plugin/ownership.md) defines acquisition and disposal, and the [inspection contract](../../lunette-contracts/inspection.luau) defines metadata.

[Shipped plugins and public imports](../README.md)
