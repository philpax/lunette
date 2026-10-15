# Architecture

## Layers

The toolkit has five layers. Each layer depends only on the layers beneath it, and each is replaceable through the plugin runtime or by choosing a different library.

| Layer | Form | Responsibility |
|---|---|---|
| Native mechanism | `lunette` native API | Layout computation, text shaping and measurement, glyph atlases |
| Host | Provider of `lunette/ui-host` | Panels, the node tree, element kind registry, drawing, hit testing, event routing, focus, inspection |
| Element kinds | Registrations on the host | Widget behaviour and props: button, toggle, column, list, and others |
| Visuals | Registrations on the host | Appearance of each kind, overridable per kind |
| Authoring | Lua libraries | Turning author code into node changes: the React-like library, or another framework |

Interactors and arbitration sit beside the host in the interaction contracts rather than inside it, because window and monitor panels consume them too. [Input](input.md) describes them.

The split follows the project's rule that the native API is mechanism and Lua is policy. Layout and text are mechanism with a long correctness tail: flexbox and grid semantics, Unicode line breaking, shaping, and font fallback. Widgets, appearance, and authoring are policy, and they stay in Lua where plugins can replace them.

### Native mechanism

The native API provides a layout tree handle and a text module. Both are stateless with respect to plugins: they hold no owners and no callbacks into plugin code other than measurement. [Layout and text](layout-and-text.md) specifies them.

### Host

The host is a provider plugin that publishes the `lunette/ui-host` capability. It owns:

- Panels: creation, pose, size, curvature, visibility, and the `vocabulary.Surface` each panel offers for picking.
- The node tree of each panel, including overlay roots for popovers, menus, tooltips, and dialogs.
- The element kind registry and the visual registry.
- Synchronisation of the node tree with the native layout tree.
- Drawing every visible node through the toolkit shader.
- Hit testing against nodes at their elevation, and routing semantic events to nodes.
- Focus within a panel, and the panel's participation in the session focus service.
- Inspection of every node by id.

The host contains no widgets. A panel with no registered kinds can hold only the host's own primitive kinds, which are described below.

### Element kinds

A standard components plugin registers the built-in kinds through the host's public registration API. A third-party plugin registers its own kinds through the same API. [Extension](extension.md#element-kinds) defines the registration.

The host itself provides a small set of primitive kinds that every other kind builds on: a box with layout style, a text run, an image, and a custom drawing node. Container behaviour such as rows, columns, grids, and stacks is layout style on a box, not a separate mechanism.

### Visuals

Each kind draws through one or more named visuals. The standard components plugin registers default visuals, and a theme plugin or a third-party plugin can override any of them. [Extension](extension.md#visuals) defines overrides.

### Authoring

The React-like library is the standard authoring framework, and every shipped consumer uses it. It is a library, not a service: a plugin imports it and mounts components onto a panel it owns. Another framework that produces the same node changes works with the same panels, kinds, and visuals. [Authoring](authoring.md) specifies the library.

## Capabilities

| Capability | Provider | Consumers |
|---|---|---|
| `lunette/ui-host` | The host plugin | The components plugin, authoring libraries through their callers, every UI consumer |
| `lunette/ui-components` | The standard components plugin | Consumers that need the standard kinds to be registered |
| `lunette/interaction` | The interaction plugin | The host, window panels, and any surface |

The components capability publishes no methods that consumers call to build UI. Its purpose is ordering: a consumer that requires it starts only after the standard kinds are registered. Its service exposes the typed element constructors for the standard kinds, so a consumer reaches `Button` through `context:require` rather than through an import of the components plugin.

## Data flow

A frame proceeds in this order. The host runs its phases from the frame service's update and draw callbacks.

1. Input. The interaction service updates interactors, arbitrates per source, and delivers semantic events to panels. The host routes each event to a node. A node updates its transient state, such as hover or press, and may call a prop callback such as `onChange`.
2. State. Prop callbacks and service notifications update component state or stores. Each update schedules the affected components to render. Nothing renders yet.
3. Render. The authoring library renders scheduled components, reconciles their output against the previous elements, and produces a list of node changes: create, update props, move, and remove.
4. Commit. The host applies the node changes, updates the native layout tree in one batched call, and recomputes layout for dirty subtrees. Kinds receive their new props and layout.
5. Draw. The host draws every visible panel through the toolkit shader. Drawing reads node state and layout and changes nothing.

Steps 2 to 4 run only when something changed. A panel with no state changes and no interaction does no rendering and no layout. It still draws every frame, because the scene is redrawn every frame.

Hover, press, drag, focus, scroll offset, and animation progress are node state. They change during step 1 and appear in step 5 without a render or a commit. A component renders only when its own state, its props, or a store it reads changes.

## Ownership and lifetime

A panel belongs to an owner, and the plugin runtime releases it with that owner. A mounted component tree belongs to its panel. Destroying the panel unmounts the tree, runs effect cleanups, and removes its nodes.

Kind registrations, visual overrides, and outlet contributions belong to the registering owner. When a kind's owner unloads, nodes of that kind are replaced by an error placeholder node that reports the missing kind. The host does not destroy the consumer's panel. The same rule applies when a consumer renders a kind that has never been registered.

A visual override ends with its owner, and the previous live visual becomes current again, which is the plugin runtime's rule for shared-value overrides.

An outlet contribution ends with its owner, and the outlet re-renders without it.

## Errors

Errors raise normally. The authoring library renders each component under a protected call. A component that raises keeps its previous output, and the library reports the error to the error service against the component's owner. A kind's event handler or visual that raises is reported against the kind's owner, and the node draws a placeholder for that frame. A failure in one plugin's subtree does not stop other subtrees or other panels from rendering.

## Rust and Lua boundary

The Rust side holds no plugin state. The layout handle owns taffy nodes keyed by integer ids that the host assigns. The text module owns shaped runs keyed the same way, and the glyph atlas. Lua owns the node tree, kinds, visuals, and the component tree.

Calls across the boundary are batched per commit. The host sends the commit's node changes as one array and receives the changed layouts as one array. [Layout and text](layout-and-text.md#native-binding) specifies the batch shape. Per-node calls are avoided because every native call allocates userdata or tables for its results.

## Module placement

The host lives at `lua/lunette-plugins/ui/host/`, the standard components at `lua/lunette-plugins/ui/components/`, and the React-like library at `lua/lunette-plugins/ui/react/` as a category library that plugins import by its documented entry. The contracts live at `lua/lunette-contracts/ui-host.luau` and `lua/lunette-contracts/ui-components.luau`. The placement follows the plugin boundary rules in [`lua/lunette-plugins/README.md`](../../../lua/lunette-plugins/README.md).
