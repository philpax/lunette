# Extension

The toolkit uses owner-scoped registrations, layered overrides, and outlet contributions. Standard widgets use the same public host contract as third-party kinds. A capability required by a standard widget must be public rather than an import of a host-private module.

Extensions can change the interface of the plugin manager and other session panels. Default appearance provides recovery from broken overrides rather than prohibiting those changes. Replacing the host itself remains a separate provider-level change.

## The element format

The [host contract](../../../lua/lunette-contracts/ui-host.luau) owns the element shape. A framework expands its own components, hooks, and contexts into elements naming host kinds. The host does not interpret framework constructs.

Stable keys preserve sibling identity and inspection paths. Positional slots retain holes from `nil` and `false` children, so optional content does not shift later siblings. The element format does not carry the proposed per-element kind-interface version.

### Mount points

A framework binds a mount point, schedules work, and submits a whole element tree while its render adapter runs. The host reconciles by slot and kind. An unmount adapter releases framework state when the mount ends. The current contract has no explicit node-patch API or post-layout adapter.

Panel roots and outlet contribution placements are public mount points. A framework does not obtain a general mount for every portal, composite slot, or offscreen list item. [Authoring](authoring.md#mounting) and [Architecture](architecture.md#data-flow) state the scheduling boundary.

## Element kinds

A kind registration supplies layout, behavior, semantics, and visual names through the host contract. The contract and checked [standard registrations](../../../lua/lunette-plugins/ui/standard/) own the supported fields. Unknown registration fields are rejected rather than interpreted as future extension features.

Layout is container style or native text. An empty, style-sized container also serves as a fixed-size visual. The host does not expose scripted layout registration, custom native measurement, arbitrary hit functions, or a mesh material slot. [Layout and text](layout-and-text.md#scripted-layout) distinguishes the separate native callback mechanism.

Props schemas report invalid or unknown values through the protected boundary. They do not guarantee that a bad element is rejected before it renders. A registration's version metadata does not establish negotiation against a version on every element or schema-superset checks for overrides.

The registering provider publishes constructors through a service so consumers require it and activation follows the dependency graph. A constructor names its kind, so later overrides apply to elements created through an existing constructor.

### Items

The host retains and inspects nodes, not arbitrary addressable items published inside one node. A canvas or text run does not acquire separate hit geometry, focus targets, or inspection records for each internal object through an item registry. Content that needs those properties uses nodes or needs an explicit contract addition.

## Composite kinds

A composite expands props, children, and declared node state into host elements. Its actions update state and emit its own callbacks, so behavior is independent of the authoring framework. An override can call the preceding expansion through `base`.

The host re-expands dirty composites. The current mount contract does not provide lazy framework content slots for hidden tab pages or per-item framework mounts for virtualisation. A composite using collections must follow the actual standard kind and authoring contracts rather than those proposed mechanisms.

## Visuals

Visuals record appearance through the host drawing contract. Registering another visual under a name layers it above the preceding one; `base` retains preceding drawing when the override needs it. Disposing the owner exposes the preceding visual. Visuals do not independently change node layout, input geometry, or behavior.

The host records a visual again when its drawing becomes dirty and reuses its primitives between recordings. A custom volume receives a draw callback each frame under its own bounds and pass-state rules. There is no public shader include or general bound-parameter expression API. [Rendering](rendering.md#drawing-api) states that distinction.

Theme tokens handle shared appearance. Theme mutation belongs to the [theme service](../../../lua/lunette-plugins/ui/theme/README.md), obtained explicitly by a caller that changes it. `host:theme()` reads the effective appearance of toolkit panels, including default appearance; it is not a second theme-mutation service.

## Behaviour overrides

Behavior replacement uses `overrideKind` with an event handler. That handler can call `base` to retain preceding behavior. The host does not expose a separate `overrideBehaviour` method. A kind override can also change props, layout, expansion, or appearance; it must preserve the expectations of existing consumers.

The plugin runtime is not a security boundary. No per-owner text-event secrecy guarantee prevents an overriding kind or ancestor handler from seeing text input. The [shared input contracts](../../../lua/lunette-contracts/docs/input.md) own routing, not sandboxing.

## Kind overrides

`overrideKind` layers a replacement under the existing kind name. Omitted fields retain the preceding registration, and `event` and `expand` receive the preceding functions as `base`. The latest live override applies, and owner disposal restores the preceding layer.

When the current registration changes, the host remakes affected nodes. It matches replacements by path below the remade node and by kind name. Focus and state fields declared by both registrations carry across. Hover and active capture carry too, so a drag continues on the remade node and release ends it there. A field absent from the replacement resets, and an unmatched removed node loses its capture without activation.

An override therefore preserves identity only where its expansion preserves the matching path and kind. Changing that structure can remove draft input or other local state. The override's errors remain attributable to its owner.

## Default appearance

Default appearance selects the base kind registration, base visual, and base theme for every toolkit panel. Accessibility settings still apply. Holding both thumbstick clicks toggles it unless that chord is disabled in the host's options. It belongs to the current host activation rather than a saved preference.

The user can enable default appearance, reach the plugin manager, and disable or reconfigure a broken override. Inspection attributes overrides to their owners. The recovery plugin provides a path when the host itself is unavailable. Pick hooks are not implemented, so bypassing them is a requirement of [#70](https://github.com/philpax/lunette/issues/70), not current default-appearance behavior.

## Outlets

An outlet is a named, typed contribution point declared in a neutral contract. Each placement binds each owner's contribution separately, with independent component state and effects. Contributions render after the panel root with the placement's props. Their order follows the outlet's comparator or contributor name, so reload does not arbitrarily reorder them.

Outlet versions provide a checked boundary: a placement accepts the same major and a contribution's equal or lower minor version. A second declaration of the same name and version with a different schema is rejected. Contribution failures are attributed to the contributor and leave the rest of the panel rendering. The host contract owns the declaration and contribution types.

Attributed outlets frame and clip each contribution and name the contributing plugin. They make origin visible and constrain accidental layout damage; they do not contain hostile code. Lifecycle controls owned by the panel remain outside contributed content.

Outlets serve custom interface. Searchable and reorderable content, such as actions or launcher entries, belongs in broker data so one consumer can search, group, and order all contributors consistently. An outlet can supplement that data when a contributor needs custom content.

## Interaction extension

The session interaction contracts support their current public providers and surface protocol. Grab-sphere interactors, transferable gesture claims, and shared manipulation are deferred in [#69](https://github.com/philpax/lunette/issues/69). Owner-scoped pick hooks and angular proximity queries are deferred in [#70](https://github.com/philpax/lunette/issues/70).

A plugin can use the host's public traversal and inspection operations. Inspection alone does not grant authority over another owner's panel or provide an unrestricted semantic-event dispatch API.

## Scope of extension

The supported extension boundaries are kind and visual registrations, kind overrides, outlet contributions, authoring adapters, and replacement providers. Presentations and surface shapes are not public registries. A custom appearance beyond recorded primitives uses the constrained volume callback or requires a contract change.

The host has no pluggable renderer or layout engine. A wholly different renderer is a replacement host, not a private import or a custom material that assumes the host's shader state.

## Replacement

The standard kinds provide base registrations for default appearance. A replacement components provider preserves the shared constructor contract and layers kind or visual changes above those bases. Replacing one kind does not require replacing the components provider.

A replacement host implements `lunette/ui-host` and preserves the [shared panel and UI guarantees](../../../lua/lunette-contracts/panels-and-ui.md). It must not rely on the standard implementation's private modules to satisfy its public service.

## Other frameworks

Another authoring library binds mount points and produces host elements. It uses the same kinds, composites, visuals, outlet ownership, traversal, and inspection. Changing the authoring model does not require changing how a panel looks or interacts.

## Contract evolution

The plugin runtime matches capability names and versions exactly, with one active provider. The declarations own that compatibility boundary. A breaking service or data-shape change requires coordinated consumer and replacement-provider updates and an explicit version decision. The current host and components services do not publish the proposed feature-set negotiation API.

Outlet major and minor versions provide their own declared compatibility checks. They do not establish a general minor-version protocol for host elements. A version field or permissive parser is not sufficient evidence that an older provider can implement new behavior.

## Trust

Plugins share the session's privileges. The toolkit is not a hostile-plugin sandbox. Ownership cleanup, attribution, bounded outlets, inspection, and default appearance limit accidental damage and let the user recover from faulty extensions.

A plugin can still imitate another interface, place content over it, or read state exposed by services. Text-event filtering and shader clipping do not provide security guarantees that the runtime itself does not enforce.
