# Ownership and lifecycle

## Service views

Consumers of one provider generation share a frozen view of its provision. Reads, iteration, and calls through a callable provision check that the provider activation is live; otherwise they raise an error naming the capability. Writes always raise. `pairs` and `#` see an empty table. A method receives the view as `self`, so mutable service state stays with the provider.

## Contexts and effects

A context is a nominal facade-created owner token. `context:effect`, `context:on`, `context:child`, and owner-scoped provider methods register work for an activation. A child is installed and enabled by `context:child`; that call returns no instance handle.

Effects are flat registrations, not nested scopes. Effects created during acquisition are siblings, and inverses run in reverse registration order. An outer inverse that needs a sibling released first must dispose it itself. Disposing an effect after its activation ends does nothing. If activation is cancelled during acquisition, the acquisition's returned inverse runs immediately and the call raises. `context:on` drops deliveries as soon as the activation is inactive, including before the subscription inverse runs.

An acquisition returns its inverse with its successful result. `context:resource(owner, acquire)` returns a value and effect only after native registration succeeds; a failed or cancelled acquisition returns no value. The acquisition remains responsible for cleaning up partial work before returning.

## Owner-scoped resources

`context:acquire`, `context:acquireDeferred`, and `context:resource` accept the provider's own context or a live dependent bound to that provider generation. They reject unrelated, forged, or ended owners before acquisition. `context:checkOwner` raises when the owner is invalid; `context:owns` answers the same test as a boolean. The `Owner` type exposes no callable acquisition method, preventing providers from bypassing these checks.

`context:acquireDeferred` registers without immediately processing pending lifecycle requests, so they wait until the next drain boundary. A provider that needs its own dependency while acquiring a dependent's resource uses its own context for that internal work, nested in the dependent-owned effect; the dependent need not declare the provider's implementation dependencies.

The dependent owns the effect and any cleanup failure. An inverse that raises during unload quarantines that owner, not the provider and its other consumers. A provider invoking an inverse directly receives its error at that call; a failure during a drain is attributed to the instance whose action failed. See [Plugin runtime](../../docs/dev/architecture.md#plugin-runtime) for graph diagnostics.

Owner-held changes to shared values are overrides: the latest live value wins, and disposal reveals the prior live value. A uniquely named registration instead rejects a name already held. Contracts define which rule applies; see [`@lunette-contracts`](../lunette-contracts/README.md).

## Instances and drains

`enable`, `disable`, and `dispose` take effect immediately or raise if rejected. `requestReload(config)` records new configuration for a later `runtime:drain()`. A drain processes pending lifecycle requests and planned actions. `runtime:snapshot()` returns detached state without callbacks or draining. Instance and owner identities are exact decimal strings.

## Decisions

A shared provider table would let consumers mutate common state and retain access after unload. Per-access views centralize revocation. The view checks the provider rather than the consumer so a dependent can still use its service while its own cleanup runs. Wrapping every method was rejected because the added stack frame misattributes errors raised at the provider's call site.

Owner-scoped acquisition uses one checked path: a callable method on `Owner` or a separate unchecked path would let providers omit the dependency and liveness check. Effects belong to the dependent so one consumer's failed inverse cannot quarantine a provider for all consumers. Overrides replace remembered-value rollback, which could restore a value belonging to an ended owner.

Effects stay flat for one reverse-registration cleanup rule. Deferred acquisition is limited to cases where a provider must finish publishing state before pending lifecycle work can observe it.

## Known gaps

A method saved while its provider is live remains callable after revocation; revocation only blocks later access through the view. Objects returned by methods need their own liveness checks. Native subscriptions or resources acquired outside plugin contexts and effects survive instance cleanup; the host has no general teardown registry.
