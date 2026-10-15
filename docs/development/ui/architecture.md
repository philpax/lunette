# Architecture

## Layers

The toolkit has five layers. Each layer depends only on the layers beneath it, and each is replaceable through the plugin runtime or by choosing a different library.

| Layer | Form | Responsibility |
|---|---|---|
| Native mechanism | `lunette` native API | Layout computation, text shaping and measurement, glyph atlases, SVG rasterisation, instance packing |
| Host | Provider of `lunette/ui-host` | The element format and mount points, panels, the node tree, composite expansion, drawing, hit testing, routing, focus, portals, animation, inspection |
| Element kinds | Registrations on the host | Widget behaviour and props: button, toggle, column, list, and others |
| Visuals | Registrations on the host | Appearance of each kind, overridable per kind |
| Authoring | Lua libraries | Turning author code into host elements: the React-like library, or another framework |

Interactors, arbitration, and drag sessions sit beside the host in the interaction contracts rather than inside it, because window and monitor panels consume them too. [Input](input.md) describes them.

The split follows the project's rule that the native API is mechanism and Lua is policy. Layout and text are mechanism with a long correctness tail: flexbox and grid semantics, Unicode line breaking, shaping, and font fallback. Widgets, appearance, and authoring are policy, and they stay in Lua where plugins can replace them.

The host is the largest layer, in the way that a browser's document tree, layout, and compositor are larger than any framework above them. Its responsibilities are the ones that need a single owner per panel: one tree, one draw order, one hit test, one focus. A framework, a kind, or a visual that took over any of them would have to coordinate with every other framework, kind, and visual on the same panel.

### Native mechanism

The native API provides a layout tree type, a text module, an SVG rasteriser, and instance packing for the toolkit's draw buffers. None of them hold plugin state: no owners, no Lua references, and no callbacks other than the layout callbacks that the host dispatches by kind. [Layout and text](layout-and-text.md) specifies them.

### Host

The host is a provider plugin that publishes the `lunette/ui-host` capability. It owns:

- The element format, mount points, and the node change API, which every authoring framework uses. [Extension](extension.md#the-element-format) defines them.
- Panels: creation, pose, size, surface shape, presentation, visibility, and the surface each panel offers for picking. A panel's name is prefixed with its owner's entry id, so two plugins can both have a panel called `Settings`.
- The node tree of each panel, including surface coordinates, conformance, transforms, and anchors, as [Spatial model](spatial-model.md) defines them, and the registries of shapes and presentations.
- The element kind registry, kind overrides, the visual registry, and the expansion of composite kinds.
- Synchronisation of the node tree with the native layout tree, and the dispatch of layout callbacks.
- Drawing every visible node through the toolkit shader, in tree order, with bound parameters.
- Hit testing, routing of semantic events through the hit path, gesture claims, and capture.
- Focus within a panel, focus scopes, the focus traversal service, and the panel's participation in the session focus service.
- Portals, including overlays, with their positioning, capture handoff, dismissal, and modality.
- The animation clock, node animation channels, and the feedback dispatcher, as [Motion and feedback](motion-and-feedback.md) describes.
- Inspection of every node by id.

The host contains no widgets. A panel with no registered kinds can hold only the host's own primitive kinds.

### Element kinds

A standard components plugin registers the built-in kinds through the host's public registration API. A third-party plugin registers its own kinds, and overrides existing ones, through the same API. [Extension](extension.md#element-kinds) defines the registration.

The host provides the primitive kinds that every other kind builds on: a box with layout style, a text run, an image, a custom drawing node, an outlet, a portal, and the virtualised list and grid. Container behaviour such as rows, columns, grids, and stacks is layout style on a box, not a separate mechanism.

### Visuals

Each kind draws through one or more named visuals. The standard components plugin registers default visuals, and a theme plugin or a third-party plugin can override any of them. [Extension](extension.md#visuals) defines overrides.

### Authoring

The React-like library is the standard authoring framework, and every shipped consumer uses it. It is a library, not a service: a plugin imports it and mounts components onto a panel it owns. Its components and hooks never reach the host. The library binds mount points and expands components into host elements, which name only kinds. Another framework that binds mount points and produces host elements works with the same panels, kinds, composites, outlets, and visuals. [Authoring](authoring.md) specifies the library.

## Capabilities

| Capability | Provider | Consumers |
|---|---|---|
| `lunette/ui-host` | The host plugin | The components plugin, authoring libraries through their callers, every UI consumer |
| `lunette/ui-components` | The standard components plugin | Consumers that need the standard kinds to be registered |
| `lunette/interaction` | The interaction plugin | The host, window panels, and any surface |
| `lunette/input-modes` | The input mode plugin | Presentations and consumers that adapt to the input mode |
| `lunette/notifications` | The notifications plugin | Any plugin that reports a transient event to the user |
| `lunette/accessibility` | The accessibility settings plugin | The host, the interaction service, the theme service, and presentations |
| `lunette/clipboard` | The clipboard plugin | Text kinds, and any plugin that copies or pastes |

The components capability exists for ordering and for constructors. A consumer that requires it starts only after the standard kinds are registered, and its service exposes the typed element constructors for the standard kinds, so a consumer reaches `Button` through `context:require` rather than through an import of the components plugin. A constructor returns a host element that names its kind, so a constructor obtained before a kind override still produces the overriding kind.

## Data flow

The host runs inside the frame service's phases and input batches, as [`lua/lunette-contracts/frame.luau`](../../../lua/lunette-contracts/frame.luau) defines them. Its steps attach at explicit points: the frame service's input batch boundary, and the interaction service's `beforePick` and `afterDelivery` hooks, which the interaction contract provides for this ordering.

1. Commit before input. At the start of each input batch, before key, text, and controller binding handlers run, the host renders the mount points with scheduled work and commits the result. Store changes made by services, compositor events, and the previous frame's `overlay` phase are therefore visible to keyboard and traversal input, so a control that a store change disabled cannot be activated by Enter or the controller's activate button.
2. Keyboard and traversal input. Key and text events and traversal actions are delivered to focused nodes.
3. Scene. Presentations update panel poses from their pose sources.
4. Anchored poses. The host recomputes the poses of anchored and attached nodes and panels from their sources, so a node attached to a hand or to a moving window is where its source is before picking.
5. Commit before picking. In the interaction service's `beforePick` hook, the host commits work scheduled since step 1, so pointer picking also sees the latest state.
6. Pointer input. The interaction service updates interactors, picks, arbitrates, and delivers events to panels. The host routes each event along the hit path, as [Input](input.md#routing) describes. Nodes update transient state, such as hover or press, and may call prop callbacks such as `onChange`. Callbacks update component state or stores, which schedules renders.
7. Render and commit. In the interaction service's `afterDelivery` hook, the host renders the scheduled mount points and applies their changes, expands composites, updates the native layout tree in one batched call, and recomputes layout for dirty subtrees. A content-sized panel resizes here, subject to the capture rule in [Layout and text](layout-and-text.md#panel-sizing).
8. Poses and layout callbacks. The host recomputes the poses that depend on this frame's layout, including attached presentations, so titlebars and orbiters follow a resized panel in the same frame, and updates the hit index. It then calls each mount point's `layout` adapter, where layout effects run with current poses. A state change made there is rendered and committed once more in this step.
9. Draw. The host advances animation channels to the frame's predicted display time and draws every visible panel. Drawing reads node state, layout, and channels, and changes nothing.

The commit steps render only when something is scheduled. A panel with no state changes and no interaction does no rendering and no layout. It still draws every frame, because the scene is redrawn every frame, but it draws from cached instance data.

Hover, press, drag, focus, scroll offset, transforms, and animation channels are node state. They change during input or animation and appear in the draw without a render or a commit. A component renders only when its own state, its props, its context, or a store it reads changes.

A store written during the `overlay` phase or later is visible from the next frame's first commit. A mount point that renders more than a fixed number of times in one frame raises. A mount point whose layout effects change state on every frame for more than a fixed number of consecutive frames, such as a toolbar whose overflow alternates, is reported once as not converging, and its layout effects stop triggering same-frame commits until its props or stores change.

`ui.mount`, and any other mount or panel creation requested during a commit or a dispatch, is queued to the end of the current step, so commits never nest.

## Ownership and lifetime

A panel belongs to an owner, and the plugin runtime releases it with that owner. A mounted tree belongs to its panel. Destroying the panel unmounts the tree, runs every effect cleanup, and removes its nodes without exit transitions.

Every subtree has an effective owner. It is the panel's owner, except inside an outlet contribution or a portal from another plugin, where it is the contributing owner. Hooks and kinds that acquire resources through a service acquire them on the effective owner. A mounted component instance is not a plugin-runtime owner. The authoring library keeps each instance's cleanups and runs them when the instance unmounts, so a component that unmounts while its panel lives releases its resources at once, and an owner that unloads releases them regardless.

Kind registrations, kind overrides, visual overrides, behaviour overrides, and outlet contributions belong to the registering owner. A consumer that requires the kind's provider unloads before the provider, as the plugin runtime orders dependants. A node whose kind's owner unloads while the node lives, which happens when the kind arrived through an outlet contribution, a portal, or a kind override, is recreated with the live registration of its kind, or replaced by a placeholder node that reports the missing kind when there is none. A capture on that node is cancelled with the reason `removed`. The same placeholder appears when a consumer renders a kind that is not registered.

A visual, behaviour, or kind override ends with its owner, and the previous live registration becomes current again, which is the plugin runtime's rule for shared-value overrides. An outlet contribution ends with its owner, and the outlet re-renders without it.

Event dispatch and commit iterate snapshots. A callback that unloads an owner, destroys a panel, or removes nodes during dispatch does not disturb the dispatch in progress: removals apply after the dispatch, and the dispatch skips nodes, handlers, and callbacks whose owners have ended.

Source reload, and a reload or replacement of the host or components provider, unmount every tree and lose every component's state together, including scroll positions, open tabs, and unsaved form input, because every UI consumer depends on them and unloads first. A reload of one consumer remounts only that consumer's trees. Panel placement survives through the arrangement service.

## Errors

Errors raise normally.

- The authoring library renders each component under a protected call. A component that raises keeps its previous output and the hook state from its previous successful render. A component that raises on its first render is replaced by a placeholder node that names the component.
- A kind's event handler, layout callback, or visual that raises is reported against the kind's owner. An override that raises is reported against the override's owner. The node draws a placeholder until its inputs change.
- Reports are deduplicated by owner, source, and message, and rate-limited, so a failure whose inputs change every frame does not report at the frame rate.

A failure in one plugin's subtree does not stop other subtrees or other panels from rendering.

The errors overlay is a protected toolkit panel. Recovery when the toolkit itself fails belongs to a separate recovery plugin that does not require the host or the components plugin. It is built on the interaction service and draws without the toolkit. It shows when the host or the components plugin is not active, or when the host reports that it is failing every frame. It lists the errors from the error stream and offers ray-pickable controls to reload the configuration and to restart in safe mode, so the session stays operable in VR even when the toolkit is broken. The compiled-in safe mode does not use the toolkit at all.

## Rust and Lua boundary

The Rust side holds no plugin state. The layout tree owns its nodes, keyed by integer ids that the host assigns. The text module owns shaped runs keyed the same way, and the glyph atlas. Lua owns the node tree, kinds, visuals, the component tree, and every function that layout calls back into, which the host dispatches by kind.

Calls across the boundary are batched per commit. The host sends the commit's node changes as one array and receives the changed layouts as one array. [Layout and text](layout-and-text.md#native-binding) specifies the batch shape. Lua describes each node's primitives once per visual run, and Rust packs the per-box and per-glyph instance data into the draw buffers. Per-node calls are avoided because every native call allocates userdata or tables for its results.

## Module placement

The host lives at `lua/lunette-plugins/ui/host/`, the standard components at `lua/lunette-plugins/ui/components/`, and the React-like library at `lua/lunette-plugins/ui/react/` as a category library that plugins import by its documented entry. The recovery plugin lives at `lua/lunette-plugins/diagnostics/recovery/`. The contracts live at `lua/lunette-contracts/ui-host.luau`, which declares the element format, the mount point adapter, the node interface, the event types, the drawing API, and the outlet declaration function, and `lua/lunette-contracts/ui-components.luau`, which declares the standard kinds' props types. The placement follows the plugin boundary rules in [`lua/lunette-plugins/README.md`](../../../lua/lunette-plugins/README.md).
