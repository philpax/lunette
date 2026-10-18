# Ownership and lifecycle

Plugin resources belong to an activation or to a caller's owner. Providers must acquire caller resources through checked context helpers; the [context declarations](adapter.luau) own their signatures.

## Service views

Consumers share a frozen provision view. Access raises once the provider starts unloading; writes always raise. Mutable state stays inside the provider, and methods receive the view as `self`. Revocation checks the provider rather than the consumer so a consumer can use services during its own cleanup.

A saved method remains callable after revocation. Returned objects therefore need their own liveness checks. `pairs` and `#` do not enumerate service fields.

## Contexts and effects

Acquire inside `init` or `build`, return the inverse with the successful acquisition, and register subscriptions through `context:on`. Clean up partial work before raising. `context:resource(owner, acquire)` makes the acquired value available only after its effect is registered; cancellation runs the returned inverse immediately and raises without returning the value.

Effects are flat siblings. Inverses run in reverse registration order, not nested acquisition order. An inverse that needs another effect released first must dispose it explicitly. Disposal after activation ends does nothing. Event delivery stops as soon as activation becomes inactive, before subscription cleanup.

## Optional services

`plugin.connectOptional(context, name, capability)` connects through one child activation without adding the capability to the parent's requirements. Its getter returns nil while the provider is unavailable and after the parent ends. A new provider activation supplies a new connection. Each call creates a separate child, so an outage affects only that capability.

A connection pairs the service with the child owner that depends on it. Owner-scoped service calls use `connection.owner`, not the parent context. Callers read the getter when using the service rather than retaining a connection across lifecycle changes. The runtime releases the connection with the child activation; the helper keeps no global registry.

## Owner-scoped resources

The provider's own context and live dependants bound to that generation are valid owners. Acquisition rejects forged, unrelated, or ended owners before doing work. A provider uses its own context for internal dependencies within the caller-owned effect; callers need not declare implementation dependencies.

The caller owns cleanup failures. A raising inverse during unload quarantines that owner, not the provider's other consumers. Deferred acquisition postpones lifecycle processing until a drain boundary and is reserved for acquisitions whose state must be published before lifecycle work observes it.

Shared-value overrides use the latest live value; disposal reveals the prior live value. Unique registrations reject collisions. [Service contracts](../lunette-contracts/README.md) define the applicable rule. Restoring a remembered value directly could restore state owned by an ended plugin.

## Instances and drains

Reload requests wait for a drain; snapshots do not drain or invoke callbacks. The [runtime specification](../../docs/development/architecture.md#plugin-runtime) owns lifecycle planning. Native subscriptions and resources acquired outside effects survive plugin cleanup: the host has no general teardown registry.
