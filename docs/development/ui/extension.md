# Extension

The toolkit extends through the plugin runtime's existing mechanisms: owner-scoped registrations, shared-value overrides, hooks that receive `base`, and entry patches. Every extension point is public, and the standard widgets use the same points as third-party plugins. A capability that a standard widget needs and a third-party widget cannot reach is a defect in the host contract.

## The element format

The host defines the element format that every authoring framework produces. An element is a table:

```luau
export type Element = {
  read kind: string,
  read version: number,
  read key: string?,
  read ref: Ref?,
  read props: { read [string]: unknown },
  read children: { read [number]: Element },
}
```

An element names a registered kind and the major version of the kind it was built against. A constructor fills both in, and a framework that builds elements by hand sets them itself. `ref` asks the host to deliver the node's handle to a framework-owned reference when the node is created, and to clear it when the node is removed. A framework's own constructs, such as the React-like library's components, hooks, and context, are expanded by the framework and never appear in a host element.

### Mount points

A mount point is a node into which one framework renders: a panel root, an outlet instance, a portal, or a virtualised item. A framework binds a mount point with an adapter that the host calls at defined moments:

- `render()`, which the host calls in each commit step for a mount point whose framework has scheduled work. A framework schedules work with `mount:schedule()`. The framework's changes are therefore committed before picking, as [Architecture](architecture.md#data-flow) describes, whatever the framework.
- `layout()`, which the host calls after layout and poses are computed, for work that reads them. The React-like library runs layout effects here.
- `unmount()`, which the host calls when the mount point ends.

Inside `render`, the framework applies elements to the mount point through the node change API. It either submits a whole element tree, which the host reconciles by kind and key, or submits explicit changes: create a node of a kind with props, set props, move a node among its siblings, and remove a node. The React-like library submits the changes its own reconciler computes.

`lua/lunette-contracts/ui-host.luau` declares the element format, the mount point adapter, the node change API, the node interface that kinds and visuals receive, the event types, and the drawing API.

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
  focus = 'pointer',
  claims = { drag = 'both', axis = true },
  response = { lift = 'hover', travel = 'press', stateLayer = true },
  event = function(node, event, base)
    if event.kind == 'drag' then
      node:emit('onChange', math.clamp(node.props.value + event.delta.y * node.props.sensitivity, 0, 1))
    elseif event.kind == 'navigate' or event.kind == 'axis' then
      node:emit('onChange', math.clamp(node.props.value + event.vector.x * node.props.step, 0, 1))
    else
      base(node, event)
    end
  end,
})
```

A registration declares:

- `name`, which is unique among live kinds. Names are namespaced by convention: the standard kinds use `lunette/`, and third-party kinds use their plugin's namespace.
- `version`, the major version of the kind's interface. The interface is its props, the node state fields its visuals read, and the names of its visuals. The host rejects an element whose version differs from the live registration's, so a change that breaks consumers or overrides is a visible error rather than a missing field.
- `props`, an object schema. The host rejects unknown props and validates values on every commit. The constructor's Luau type is derived from the schema through `schema.Props`, which makes every field read-only and adds an indexer for positional children, so the type and the runtime check have one source. Callbacks use `schema.callback`.
- `role` and `semantics`. The role comes from the closed set in the contract vocabulary, such as `button`, `toggle`, `slider`, `textbox`, `list`, `listitem`, `dialog`, or `group`. `semantics` returns the accessible name, value, range, and states such as checked, expanded, and selected. [Accessibility](accessibility.md#roles-and-semantics) describes their use.
- `layout`, which is `container` for a kind whose children the layout engine places, `leaf` with a size descriptor or a measure function for a kind that sizes itself, or `custom` with a layout function. [Layout and text](layout-and-text.md#custom-layout) defines them.
- `visuals`, the names of the visuals the kind draws through.
- `focus`, the focus policy: `text`, `pointer`, or `none`, as [Input](input.md#focus) defines. A `text` kind also declares its input hint.
- `captures`, how many captures the kind accepts at once. More than one enables the `transform` gesture.
- `claims`, the gestures the kind consumes, as a table or as a function evaluated when the gesture resolves. [Input](input.md#gesture-claims) defines claims. `holdDuration` sets the kind's hold duration.
- `response`, the standard interaction response that the host applies: hover lift, press travel, the state layer, and the feedback events for hover, press, and activation. Third-party kinds get the same feel as the standard kinds by declaring it, and a behaviour handler can adjust it through `base`.
- `motion`, the default `enter` and `exit` specs, and `cursor`, the cursor hint, as [Motion and feedback](motion-and-feedback.md) describes.
- `event`, which receives semantic events as they bubble, as [Input](input.md#routing) describes. `node:emit` calls a prop callback under a protected call against the consumer's owner.
- `hit`, an optional function that replaces the default hit volume and returns a hit record, as [Spatial model](spatial-model.md#hit-volumes) describes.
- `items`, an optional function that publishes addressable items inside the node.
- `inspect`, which adds kind-specific fields to the node's inspection record.

The host rejects unknown registration fields, so a kind written against a newer host contract fails visibly on an older host rather than losing a field silently.

The registration returns a typed element constructor. The registering plugin publishes the constructor through its own service, so consumers obtain it through `context:require` and the plugin graph orders them after the registration. A constructor produces an element that names its kind, so it reaches whichever registration of that name is live at commit.

### Items

A kind whose content is not made of nodes, such as a graph canvas with nodes and edges, a colour wheel, a pie of sectors, or a text node with links, publishes items. An item has an id, a shape from the closed set in [Spatial model](spatial-model.md#hit-volumes), an enabled state with an optional disabled reason, a role and semantics, and whether it is focusable. The host re-evaluates a node's items when its props, layout, or transform change. The host treats items as targets for hover, capture, focus traversal, disabled reasons, feedback, and inspection, and events carry the item id. An edge in the plugin manager's graph is therefore focusable without pointing and addressable by id in a test.

## Composite kinds

A composite kind is built from other kinds. It registers an `expand` function instead of visuals and layout:

```luau
host:registerKind(context, {
  name = 'lunette/dropdown',
  version = 1,
  props = dropdownProps,
  role = 'combobox',
  state = { open = false },
  expand = function(props, children, state, actions)
    return {
      button { key = 'trigger', label = selectedLabel(props), trailingIcon = 'chevron-down',
        onActivate = function() actions.setState { open = not state.open } end },
      if state.open then portal { key = 'menu', anchor = 'trigger',
        list { items = props.options, value = props.value, onChange = function(value)
          actions.setState { open = false }
          actions.emit('onChange', value)
        end },
      } else nil,
    }
  end,
})
```

`expand` is framework-free: it receives the props, the children, the node's declared state, and actions, and returns host elements. `actions.setState` updates the node's state, and `actions.emit` calls one of the composite's own prop callbacks. Callbacks that `expand` gives to its children close over the actions, so a child's change reaches the composite. The host re-expands the composite when its props or its state change.

A child's value change also bubbles to its ancestors as a `change` event that carries the child's key and value. A composite's `event` handler can observe it, so a search field composite sees what is typed into its inner text field without the text field's handler being replaced.

Every framework renders composite kinds the same way, because the host expands them. A dropdown created through a signals library opens, positions, and dismisses exactly as one created through the React-like library. The standard dropdown, search field with suggestions, tabs, navigation stack, dialog, toast, and Markdown view are composites.

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

A visual runs when its node is created, when the node's props, layout, theme, or visual state change, and when the visual stack for its name changes. A registration or disposal of an override invalidates every node that uses the visual in every panel. Between runs, the host draws the node from cached instance data. Appearance that changes every frame, such as a glow that follows a fingertip or a spinner's rotation, uses bound parameters that the shader evaluates, as [Rendering](rendering.md#bound-parameters) describes, not a visual that runs every frame.

A theme plugin that wants a different visual language registers overrides for the visuals it changes. Colours, spacing, type, radii, elevation, and motion come from tokens, so most restyling needs no visual override. [Theming](theming.md) describes tokens.

## Behaviour overrides

A kind's event handler receives `base`, and the host exposes `overrideBehaviour(owner, kind, handler)` with the same stacking rule as visuals. A handler that calls `base` adjusts behaviour while keeping the default. Behaviour overrides apply to composite kinds through the composite's own event handler. A behaviour override cannot add props, because the props schema belongs to the kind. A behaviour change that needs new props is a new kind, usually a composite.

Key and text events on a text-input kind are never delivered to a behaviour override from another owner. An override can therefore not read what a user types into a field through the field's kind. Ancestor scopes and panel shortcuts still see key events as they bubble, as [Input](input.md#focus-scopes-and-key-routing) describes, so a panel's owner sees keys typed into fields contributed to its panel.

An override that raises is reported against its own owner, and the node falls back to the next handler in the stack for that event.

## Kind overrides

`host:overrideKind(context, name, registration)` replaces a kind under its existing name, with the same stacking rule as visuals: the latest live override wins, and disposing it reveals the previous registration. Nodes of the kind are recreated when the live registration changes, so each node has exactly one owner for its behaviour at any time. The override must keep the kind's major version, so consumers' constructors keep working.

A plugin that ships a different slider therefore overrides `lunette/slider` from its own activation, requiring whatever it needs, with its errors attributed to it. Two plugins that override different kinds do not interact, and the user disables either one from the plugin manager.

## Protected panels

A panel created with `protected = true` draws and behaves with the shipped standard components, ignoring every visual, behaviour, and kind override and the configured kind set. It uses the base theme's tokens rather than the selected theme. Session-modal dialogs do not block it, and the interaction service's `pick` hooks do not apply to it. The host keeps the standard registrations available for protected panels even when a replacement components provider is active.

The plugin manager and the recovery surfaces use protected panels, so no override, theme, replacement provider, or modal dialog can make the interface that disables them invisible, unreadable, inert, or unreachable. Inspection reports which overrides apply to each node and which owner registered them.

## Outlets

An outlet is a named, typed point in a tree where other plugins contribute subtrees. A plugin declares an outlet in its contract module through a pure function of the host contract:

```luau
local uiHost = require '@lunette-contracts/ui-host'

local settingsOutlet = uiHost.outlet {
  name = 'lunette/manager/settings',
  version = 1,
  props = schema.object { entry = schema.string() },
  attributed = true,
}
```

A tree places it with the host's outlet kind, `c.Outlet { outlet = settingsOutlet, props = { entry = selected } }`. Another plugin contributes to it through the host, with a mount point adapter that receives the outlet's props, or through its framework's adapter:

```luau
ui.contribute(context, settingsOutlet, ui.component('BackdropSettings', function(props: { entry: string })
  if props.entry ~= 'desktop/backdrop' then return nil end
  return BackdropSettingsForm { backdrop = backdrop }
end))
```

The host rejects a contribution whose outlet version differs from the placed outlet's, and reports the mismatch against the contributor. Each contribution renders under its own owner, which is the effective owner of its subtree. It is removed when its owner unloads. Each placement of an outlet is a separate instance, so an outlet shown in a wrist panel and a summoned panel at once renders each contribution twice, with separate state and effects. Contributions render in registration order unless the outlet declares an ordering function. A contribution's error is reported against its owner and does not affect the outlet's own component.

An outlet declared `attributed` draws each contribution inside a host-drawn frame that names the contributing plugin, so a contribution cannot pass itself off as the outlet owner's own interface. The plugin manager's outlets are attributed.

Outlets serve custom interface. Content that the user searches, filters, groups, or reorders, such as menu actions and launcher entries, is data: the menu broker and the catalog contracts publish it, and the panel that shows it renders it, so search and grouping work across every contributor. A launcher can still offer an outlet for a contributor that needs a custom tile.

## Interaction extension

The interaction service is extended in the same way:

- A plugin can add a source or an interactor, such as a dwell interactor, a head pointer, or switch access, and it receives the same arbitration and semantic events as the standard ones. An interactor with a new shape registers that shape's query with the host, so toolkit nodes answer it. Window surfaces answer rays only.
- `interaction:registerPick(context, hook)` adds an owner-scoped `pick` hook. Hooks stack in registration order, each receiving the interactor, the candidates, and `base`. A hook can query nodes within an angular radius of a ray that missed, so a bubble cursor or magnetic snapping can choose a target the ray did not hit. Protected panels ignore pick hooks.
- A plugin that drives the interface by other means, such as voice commands, resolves a node through inspection by role and name and asks the host to dispatch a semantic event to it.

## Scope of extension

| Change | Mechanism | Example |
|---|---|---|
| Appearance, broadly | Tokens and themes | A dense or high-contrast theme |
| Appearance of one kind | A visual override | A glow around the standard button, or a skeuomorphic slider |
| Appearance, beyond the primitives | A mesh with a custom material that includes the toolkit's shader code | Holographic panels or scanlines |
| Behaviour of one kind | A behaviour override | A slider that drags relative to the press point |
| One kind entirely | A kind override | A different slider |
| New widgets | `registerKind`, leaf, custom, or composite | A knob, a colour wheel, or a timeline |
| Content in another plugin's panel | An outlet contribution | A plugin's settings page in the manager |
| Placement | A registered presentation | A follow presentation for toasts, or a palm-up hand menu |
| Surfaces | A registered shape | A forearm cylinder or a sphere patch |
| Input | A source, an interactor, or a `pick` hook | Dwell, gaze with pinch, switch access, or a bubble cursor |
| The whole widget set | A replacement provider of `lunette/ui-components` | A different design language |
| Everything | A replacement provider of `lunette/ui-host` | A different toolkit behind the same contract |

The host has no pluggable renderer, material system, or layout engine. A custom appearance beyond the drawing API's primitives uses the mesh slot, and a whole different renderer is a replacement host.

## Replacement

A configuration replaces a whole layer with an entry patch.

- Replacing the standard components plugin replaces every standard kind. A replacement provides the same `lunette/ui-components` capability and the same props types from `ui-components.luau`, so consumers keep working. Protected panels keep the shipped standard components.
- Replacing the host replaces drawing, hit testing, layout synchronisation, and composite expansion. A replacement implements `lunette/ui-host` and preserves the guarantees in the host contract.

Replacing a single kind is a kind override, as described above, not a configuration change. Two live registrations of one kind name are rejected, because a node's behaviour must have one owner.

## Other frameworks

An authoring framework is a library that binds mount points and produces host elements for them. The React-like library is one. A signals library or an immediate-mode library binds mount points through the same adapter, produces the same elements through the same node change API, and contributes to outlets through its own adapter.

Panels built with different frameworks use the same kinds, composites, visuals, theme, focus traversal, and inspection. One panel can mix frameworks, because a mount point can hold a subtree from another framework. A framework with different sensibilities therefore changes how authors write UI, not how the UI looks or behaves.

## Contract evolution

The plugin runtime matches contracts by exact name and version, and a capability has one active provider. The host contract therefore changes in two ways:

- An additive change, such as a new optional event field, a new drawing primitive, or a new optional registration field, keeps the capability's version. The host service publishes a feature set, and a kind, framework, or consumer that needs a feature asserts it at activation, so a newer plugin on an older or replacement host fails at activation with a named missing feature rather than at the point of use.
- A breaking change, such as renaming a node state field or changing an event's shape, bumps the capability's version, and every kind, visual, and framework moves with it. Breaking changes are therefore batched, and the feature set covers additions between them.

The node interface that visuals and behaviour overrides read is declared as types in `ui-host.luau`, so a breaking change appears as a type error in every override rather than as a `nil` at draw time. Kinds carry their own interface versions, and outlets carry their own versions, so a change to one widget or one outlet does not bump the host.

## Trust

The plugin runtime is not a security boundary, and the toolkit inherits that. Every plugin runs with the session's privileges, and the toolkit does not attempt to contain a hostile plugin. It does limit what a faulty or careless plugin can do by accident, and it makes the origin of every part of the interface visible:

- Text-input events reach no behaviour override from another owner.
- Attributed outlets name the contributing plugin.
- Protected panels ignore overrides, replacement components, themes, pick hooks, and session modality.
- Session modality and the `dialog` elevation are available only to portals opened by the standard dialog kind, as [Presentations](presentations.md#modality) describes.
- Inspection records the owner of every panel, node, contribution, and override.

A plugin that places a panel over another plugin's interface, draws a convincing imitation of another plugin's interface, or reads another plugin's state through its services is not prevented. The user's protection against such a plugin is not installing it.
