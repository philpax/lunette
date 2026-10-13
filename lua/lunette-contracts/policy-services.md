# Policy services

Consumers and replacement providers preserve these guarantees. The [contract declarations](.) own service shapes and versions; chooser algorithms and configuration defaults belong to implementations.

## Brokers

Change listeners belong to owners, and one listener's failure does not stop others. Inspection invokes no plugin callbacks.

Bindings match exactly the named modifiers and consume matching presses, repeats, and raising callbacks. They run in [the binding phase](docs/input.md#frame-dispatch) before client delivery. Menu actions are data, not rendered controls; invocation through a listed token refuses an action that replaced it under the same id. Removed actions cannot be updated.

Layouts arrange caller-supplied live panels without owning panels or tags. The caller decides when to apply them, including repeated application of continuous layouts. Separate registration permits several layouts under one capability.

## Laser

A hand has one live laser owner. Attaching another owner raises.

## Tags

A tag lives while any owner holds it. Membership requires an owner addition and no owner exclusion; owners can remove only their own membership. Panel removal drops membership without a tag-change notification, so consumers also follow panel lifetime. Selection uses the latest live owner override and reveals the previous selection on disposal. Creation, destruction, selection, and membership changes notify listeners.

## Rules and placement

Rule sources merge in ascending precedence; higher precedence wins conflicts. [Vocabulary](vocabulary.luau) names shipped positions. Source names and binding chords reject live collisions. Unsupported match keys raise; unresolved property keys pass through. Rules remain independent of panels and tags.

Placement joins resolved rules, panels, and tags. Request values override rules, then defaults fill gaps. Placement ends with its effect, owner, or panel. Mapping properties to panel options remains provider policy.

## Errors

The error service retains the latest report. Reports raised during listener delivery update it without another delivery round, preventing a failing presenter from feeding itself. Listener failures still reach the native error boundary. Presentation belongs to consumers.

## Pacing and scale

Choosers are pure and resource-free. Callers create one per window or output, supply observations, and apply the answer. Services read no scene and change no native settings. Algorithms and thresholds are not contract guarantees.
