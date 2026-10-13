# Policy services

The guarantees below apply to replacement providers.

## Brokers

Brokers that provide change notifications report their own changes through owner-scoped listeners. A failure in one listener does not stop other listeners.

Bindings match exactly the named modifiers, in any order. A matching press runs once and is consumed; repeats and raising callbacks are also consumed. Bindings run in the `binding` phase so a command press does not reach a client. Phase ordering belongs to [Input](docs/input.md#frame-dispatch).

The menu stores actions but does not render them. Change notifications follow registration, update, or removal. Invocation with a listed row's token refuses a replacement that took the same id. Action callbacks run under the registering owner's protected context; updating a removed action answers false.

Layouts receive the live panels supplied by the caller and own no panels or tags. Options belong to the registering plugin. The consumer decides when to apply a layout; `continuous` marks one for repeated application.

## Laser

A hand has one live laser owner; attaching to a hand held by another owner raises.

## Tags

A tag exists while at least one owner holds it; hold options apply when the tag is created. Membership exists while some owner adds a panel and no owner excludes it. Exclusion is an owner-scoped effect, and an owner can remove only its own membership. A removed panel leaves tag membership without a separate tag-change notification; panel removal is announced through [panels](panels.luau).

Selection is an owner-held override; the most recent live override wins, and ending it reveals the previous one. Change notifications cover creation, destruction, selection, and membership, with an optional tag filter.

## Rules and placement

Rule sources merge in ascending precedence, so higher precedence wins on conflicts. [`vocabulary.PRECEDENCE`](vocabulary.luau) names the shipped positions. Source names and binding chords have one live holder; collisions raise. Unsupported match keys raise, while property keys not mapped by placement pass through resolution. Rules do not depend on panels or tags.

Placement joins rules, panels, and tags: it resolves properties, creates a window panel, and joins named tags. Request values override resolved rules; defaults fill remaining gaps. The placement ends with its effect, owner, or panel. Notifications cover all placements. Mapping resolved properties to panel options is placement-provider policy.

## Errors

The error service retains the latest report. A report raised during listener delivery updates that state without another delivery round, so a raising presenter cannot feed itself. Listener failures still reach the native error boundary. Presentation is consumer policy.

## Pacing and scale

The services return pure, resource-free chooser objects. Callers create a pacer per window or chooser per output and supply observations or distance; the service reads no scene and applies no native settings. Consumers apply the returned answers. Chooser algorithms and thresholds are not contract guarantees.

## Decisions

A desktop dispatcher was rejected for bindings because its outage would stop all typing. A contract per layout was rejected because it permits only one implementation. Drops use a separate broker so neither panels nor interaction is required just to notify listeners; ordering belongs to [Input](docs/input.md#drops). Polling registries was rejected because each broker already knows when its contents change. Owner-held membership prevents one owner's removal from outliving its authority. Placement remains separate from rules, so rule resolution does not depend on panels or tags. Caller-owned choosers need no service-wide cleanup protocol.
