# Extension

The toolkit extends through the plugin runtime's existing mechanisms: owner-scoped registrations, shared-value overrides, hooks that receive `base`, and entry patches. Every extension point is public, and the standard widgets use the same points as third-party plugins. A capability that a standard widget needs and a third-party widget cannot reach is a defect in the host contract.

## The element format

The host defines the element format that every authoring framework produces. An element is a table:

```luau
export type Element = {
  read kind: string,
  read key: string?,
  read props: { read [string]: unknown },
  read children: { read [number]: Element },
}
```

An element names a registered kind. A framework's own constructs, such as the React-like library's components, hooks, and context, are expanded by the framework and never appear in a host element.

The node change API applies elements to a panel. A framework either submits a whole element tree for a mount point, and the host reconciles it by kind and key, or submits explicit changes: create a node of a kind with props, set props, move a node among its siblings, and remove a node. The React-like library submits the changes its own reconciler computes. A mount point is a node, such as a panel root, an outlet instance, or a portal, into which one framework renders.

`lua/lunette-contracts/ui-host.luau` declares the element format, the node change API, the node interface that kinds and visuals receive, the event types, and the drawing API.

## Element kinds

An element kind is registered on the host with an owner:

```luau
local knob = host:registerKind(context, {
  name = 'example/knob',
  version = 1,
  props = knobProps,
  role = 'slider',
  semantics = function(node) return { name = node.props.label, value = node.props.value, min = 0, max = 1 } end,
  layout = { kind = 'leaf', size = { aspect = 1, preferredWidth = 0.04 } },
  visuals = { 'example/knob' },
  focusable = true,
  claims = { drag = 'both' },
  event = function(node, event, base)
    if event.kind == 'drag' then
      node:emit('onChange', math.clamp(node.props.value + event.delta.y * node.props.sensitivity, 0, 1))
    end
  end,
})
```

A registration declares:

- `name`, which is unique among live kinds. Names are namespaced by convention: the standard kinds use `lunette/`, and third-party kinds use their plugin's namespace.
- `version`, the major version of the kind's props. A constructor records the version it was built against, and the host rejects an element whose version differs from the live registration's, so a props change that breaks consumers is a visible error rather than a missing field.
- `props`, an object schema. The host rejects unknown props and validates values on every commit. The constructor's Luau type is derived from the schema through `schema.Input`, so the type and the runtime check have one source. Children are a separate `children` field of the schema, typed as `ui.Children`, and callbacks use `schema.callback`.
- `role` and `semantics`. The role comes from the closed set in the contract vocabulary, such as `button`, `toggle`, `slider`, `textbox`, `list`, `listitem`, `dialog`, or `group`. `semantics` returns the accessible name, value, range, and states such as checked, expanded, and selected. [Accessibility](accessibility.md#roles-and-semantics) describes their use.
- `layout`, which is `container` for a kind whose children the layout engine places, `leaf` with a size descriptor or a measure function for a kind that sizes itself, or `custom` with an arrange function for a container with its own placement. [Layout and text](layout-and-text.md#layout-callbacks) defines both callbacks.
- `visuals`, the names of the visuals the kind draws through.
- `focusable`, whether the kind takes session focus when pressed, whether it takes text input and therefore summons the virtual keyboard, and whether it accepts several captures at once. [Input](input.md#focus) defines the focus policies.
- `claims`, the gestures the kind consumes: drag along one axis or both, scroll along one axis or both, and the transform gesture of several captures. [Input](input.md#gesture-claims) defines how claims decide the winner.
- `event`, which receives semantic events as they bubble, as [Input](input.md#routing) describes. `node:emit` calls a prop callback under a protected call against the consumer's owner.
- `hit`, an optional function that replaces the default hit volume, as [Spatial model](spatial-model.md#hit-volumes) describes.
- `items`, an optional function that publishes addressable items inside the node.
- `inspect`, which adds kind-specific fields to the node's inspection record.

The registration returns a typed element constructor. The registering plugin publishes the constructor through its own service, so consumers obtain it through `context:require` and the plugin graph orders them after the registration. A constructor produces an element that names its kind, so it reaches whichever registration of that name is live at commit.

### Items

A kind whose content is not made of nodes, such as a graph canvas with nodes and edges, a colour wheel, or a pie of sectors, publishes items. An item has an id, a shape or bounds in the node's local space, an enabled state with an optional disabled reason, a role and semantics, and whether it is focusable. The host treats items as targets for hover, capture, focus traversal, disabled reasons, feedback, and inspection, and events carry the item id. An edge in the plugin manager's graph is therefore focusable without pointing and addressable by id in a test.

## Composite kinds

A composite kind is built from other kinds. It registers an `expand` function instead of visuals and layout:

```luau
host:registerKind(context, {
  name = 'lunette/dropdown',
  version = 1,
  props = dropdownProps,
  role = 'combobox',
  state = { open = false },
  expand = function(props, children, state)
    return {
      button { key = 'trigger', label = selectedLabel(props), trailingIcon = 'chevron-down', ref = 'trigger' },
      if state.open then portal { key = 'menu', anchor = 'trigger', list { items = props.options, value = props.value } } else nil,
    }
  end,
  event = function(node, event, base) ... end,
})
```

`expand` is stateless and framework-free: it receives the props, the children, and the node's declared state, and returns host elements. The host re-expands the composite when its props or its state change. State changes come from the composite's own `event` handler, which updates `node.state`. A composite that needs more than node state, such as an asynchronous search over a catalog, is a component in an authoring framework rather than a composite kind, or a leaf kind with its own drawing.

Every framework renders composite kinds the same way, because the host expands them. A dropdown created through a signals library opens, positions, and dismisses exactly as one created through the React-like library.

## Visuals

A visual draws a node's appearance with the host's drawing API, which applies the node's pose, clip, and surface shape. [Rendering](rendering.md#drawing-api) describes the API. A visual receives the node, the drawing API, and `base`:

```luau
host:overrideVisual(context, 'lunette/button', function(node, draw, base)
  base(node, draw)
  if node.state.focusVisible then
    draw:ring(node.bounds, { width = 0.002, color = node.theme.colors.focus, radius = node.theme.radii.control })
  end
end)
```

Calling `base` keeps the previous visual and adds to it. Omitting it replaces the appearance. An override cannot change hit geometry, layout, or behaviour. Those belong to the kind.

The visual stack for a name has the kind's default visual at its base, and overrides above it. The latest live override wins, and disposing it reveals the previous one, which is the plugin runtime's rule for shared-value overrides. A default visual registered after an override sits beneath it, so an override's position does not depend on activation order. An overriding plugin requires the capability of the plugin that registers the visual, so the graph orders it after that plugin.

A visual runs when its node is created, when the node's props, layout, theme, or visual state change, and when the visual stack for its name changes. A registration or disposal of an override invalidates every node that uses the visual in every panel. Between runs, the host draws the node from cached instance data. A visual does not animate by running every frame. It reads animation channels, which the host applies in the shader, as [Motion and feedback](motion-and-feedback.md#animation-channels) describes.

A theme plugin that wants a different visual language registers overrides for the visuals it changes. Colours, spacing, type, radii, elevation, and motion come from tokens, so most restyling needs no visual override. [Theming](theming.md) describes tokens.

## Behaviour overrides

A kind's event handler receives `base`, and the host exposes `overrideBehaviour(owner, kind, handler)` with the same stacking rule as visuals. A handler that calls `base` adjusts behaviour while keeping the default. Behaviour overrides apply to composite kinds through the composite's own event handler. A behaviour override cannot add props, because the props schema belongs to the kind. A behaviour change that needs new props is a new kind, usually a composite.

Key and text events on a text-input kind are delivered only to the kind's own handler, never to a behaviour override from another owner. An override can therefore not read what a user types into a field in another plugin's panel.

An override that raises is reported against its own owner, and the node falls back to the next handler in the stack for that event.

## Protected panels

A panel created with `overrides = 'none'` draws with the default visuals and handles events with the default behaviours, ignoring every override. Theme tokens still apply. The plugin manager and the recovery surfaces use it, so a faulty theme override cannot make the interface that disables the theme invisible or inert. Inspection reports which overrides apply to each node and which owner registered them.

## Outlets

An outlet is a named, typed point in a tree where other plugins contribute subtrees. A plugin declares an outlet in its contract module:

```luau
local settingsOutlet = host.outlet {
  name = 'lunette/manager/settings',
  version = 1,
  props = schema.object { entry = schema.string() },
  attributed = true,
}
```

A tree places it with the host's outlet kind, `c.Outlet { outlet = settingsOutlet, props = { entry = selected } }`. Another plugin contributes to it through the host, with a function that receives a mount point and the outlet's props, or through its framework's adapter:

```luau
ui.contribute(context, settingsOutlet, ui.component('BackdropSettings', function(props: { entry: string })
  if props.entry ~= 'desktop/backdrop' then return nil end
  return BackdropSettingsForm { backdrop = backdrop }
end))
```

Each contribution renders under its own owner, which is the effective owner of its subtree. It is removed when its owner unloads. Each placement of an outlet is a separate instance, so an outlet shown in a wrist panel and a summoned panel at once renders each contribution twice, with separate state and effects. Contributions render in registration order unless the outlet declares an ordering function. A contribution's error is reported against its owner and does not affect the outlet's own component.

An outlet declared `attributed` draws each contribution inside a host-drawn frame that names the contributing plugin, so a contribution cannot pass itself off as the outlet owner's own interface. The plugin manager's outlets are attributed.

Outlets serve custom interface. Content that the user searches, filters, groups, or reorders, such as menu actions and launcher entries, is data: the menu broker and the catalog contracts publish it, and the panel that shows it renders it, so search and grouping work across every contributor. A launcher can still offer an outlet for a contributor that needs a custom tile.

## Interaction extension

The interaction service is extended in the same way. A plugin can add a source or an interactor, such as a dwell interactor, a head pointer, or switch access, and it receives the same arbitration and semantic events as the standard ones. The service exposes a `pick` hook that receives the interactor, the candidate hits, and `base`, so a plugin can implement target assistance such as a bubble cursor or magnetic snapping. A plugin that drives the interface by other means, such as voice commands, resolves a node through inspection by role and name and asks the host to dispatch a semantic event to it.

## Scope of extension

| Change | Mechanism | Example |
|---|---|---|
| Appearance, broadly | Tokens and themes | A dense or high-contrast theme |
| Appearance of one kind | A visual override | A glow around the standard button, or a skeuomorphic slider |
| Appearance, beyond the primitives | A mesh with a custom shader that includes the toolkit's vertex mapping | Holographic panels or scanlines |
| Behaviour of one kind | A behaviour override | A slider that drags relative to the press point |
| New widgets | `registerKind`, leaf or composite | A knob, a colour wheel, or a timeline |
| Content in another plugin's panel | An outlet contribution | A plugin's settings page in the manager |
| Placement | A registered presentation | A follow presentation for toasts, or a palm-up hand menu |
| Input | A source, an interactor, or the `pick` hook | Dwell, gaze with pinch, switch access, or a bubble cursor |
| One standard kind | A kind factory in the components plugin's configuration | A different slider |
| The whole widget set | A replacement provider of `lunette/ui-components` | A different design language |
| Everything | A replacement provider of `lunette/ui-host` | A different toolkit behind the same contract |

The host has no pluggable renderer, material system, or layout engine. A custom appearance beyond the drawing API's primitives uses the mesh slot, and a whole different renderer is a replacement host.

## Replacement

A configuration replaces any layer with an entry patch.

- Replacing the standard components plugin replaces every standard kind. A replacement provides the same `lunette/ui-components` capability and the same props types from `ui-components.luau`, so consumers keep working.
- Replacing one standard kind uses the components plugin's `kinds` setting, which maps a kind name to a factory. An entry patch supplies the factory through the existing typed-patch path, and the components plugin registers the factory's kind under the standard name. Consumers keep their constructors, because constructors resolve kinds by name.
- Replacing the host replaces drawing, hit testing, layout synchronisation, and composite expansion. A replacement implements `lunette/ui-host` and preserves the guarantees in the host contract.

Two live registrations of one kind name are rejected, because a node's behaviour must have one owner.

## Other frameworks

An authoring framework is a library that produces host elements for a mount point. The React-like library is one. A signals library or an immediate-mode library produces the same elements through the same node change API, and it contributes to outlets through its own adapter.

Panels built with different frameworks use the same kinds, composites, visuals, theme, focus traversal, and inspection. One panel can mix frameworks, because a mount point can hold a subtree from another framework. A framework with different sensibilities therefore changes how authors write UI, not how the UI looks or behaves.

## Contract evolution

The plugin runtime matches contracts by exact name and version. The host contract therefore changes in two ways:

- An additive change, such as a new optional event field, a new drawing primitive, or a new optional registration field, keeps the capability's version. Kinds and visuals ignore fields they do not read.
- A breaking change, such as renaming a node state field or changing an event's shape, bumps the capability's version, and every kind, visual, and framework moves with it.

The node interface that visuals and behaviour overrides read is declared as types in `ui-host.luau`, so a breaking change appears as a type error in every override rather than as a `nil` at draw time. Kinds carry their own props versions, and outlets carry their own versions, so a change to one widget or one outlet does not bump the host.

## Trust

The plugin runtime is not a security boundary, and the toolkit inherits that. Every plugin runs with the session's privileges, and the toolkit does not attempt to contain a hostile plugin. It does limit what a faulty or careless plugin can do by accident, and it makes the origin of every part of the interface visible:

- Text-input events reach only the text-input kind's own handler.
- Attributed outlets name the contributing plugin.
- Protected panels ignore overrides.
- Dialog elevation is reserved for portals opened by a dialog kind, and a dialog's modality is set by the host, as [Presentations](presentations.md#modality) describes.
- Inspection records the owner of every panel, node, contribution, and override.

A plugin that places a panel over another plugin's confirmation dialog, draws a convincing imitation of another plugin's interface, or reads another plugin's state through its services is not prevented. The user's protection against such a plugin is not installing it.
