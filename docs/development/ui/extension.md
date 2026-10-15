# Extension

The toolkit extends through the plugin runtime's existing mechanisms: owner-scoped registrations, shared-value overrides, hooks that receive `base`, and entry patches. Every extension point is public, and the standard widgets use the same points as third-party plugins. A capability that a standard widget needs and a third-party widget cannot reach is a defect in the host contract.

Extension is not fenced off from any part of the interface. A plugin can restyle or replace the widgets of the plugin manager, the wrist menu, and the virtual keyboard as freely as any other panel. Recovery from an extension that breaks the interface is a switch back to the shipped defaults, as [Default appearance](#default-appearance) describes, not a restriction on what can be extended.

## The element format

The host defines the element format that every authoring framework produces. An element is a table:

```luau
export type Element = {
  read kind: string,
  read version: Version,
  read key: string?,
  read ref: Ref?,
  read props: { read [string]: unknown },
  read children: { read [number]: Element },
}
```

An element names a registered kind and the version of the kind it was built against, a major and a minor number. A constructor fills both in, and a framework that builds elements by hand sets them itself. `ref` asks the host to deliver the node's handle to a framework-owned reference when the node is created, and to clear it when the node is removed. A framework's own constructs, such as the React-like library's components, hooks, and context, are expanded by the framework and never appear in a host element. Keys must not contain the characters that ids use as separators: `/`, `:`, `@`, and `#`.

### Mount points

A mount point is a node into which one framework renders: a panel root, an outlet instance, a portal, a virtualised item, or a composite's content slot. A framework binds a mount point with an adapter that the host calls at defined moments:

- `render()`, which the host calls in each commit for a mount point whose framework has scheduled work. A framework schedules work with `mount:schedule()`. The framework's changes are therefore committed before input is delivered, as [Architecture](architecture.md#data-flow) describes, whatever the framework.
- `layout()`, which the host calls after layout and poses are computed, for work that reads them. The React-like library runs layout effects here.
- `unmount()`, which the host calls when the mount point ends.

Inside `render`, the framework applies elements to the mount point through the node change API. It either submits a whole element tree, which the host reconciles by kind and key, or submits explicit changes: create a node of a kind with props, set props, move a node among its siblings, and remove a node. The React-like library submits the changes its own reconciler computes. One panel mixes frameworks only through mount points, such as an outlet or a portal whose contribution is written with another framework.

`lua/lunette-contracts/ui-host.luau` declares the element format, the mount point adapter, the node change API, the node interface that kinds and visuals receive, the event types, the drawing API, the outlet declaration function, and `Props`, the type function that derives a constructor's props type from a kind's props schema.

## Element kinds

An element kind is registered on the host with an owner:

```luau
local knob = host:registerKind(context, {
  name = 'example/knob',
  version = { major = 1, minor = 0 },
  props = knobProps,
  role = 'slider',
  semantics = function(node) return { name = node.props.label, value = node.props.value, min = 0, max = 1 } end,
  layout = { kind = 'leaf', size = { aspect = 1, preferredWidth = 0.04 } },
  visuals = { 'example/knob' },
  focus = 'pointer',
  engage = true,
  claims = { drag = 'both', axis = true },
  response = { lift = 'hover', travel = 'press', stateLayer = true },
  event = function(node, event, base)
    if event.kind == 'drag' then
      node:emit('onChange', math.clamp(node.props.value + event.delta.y * node.props.sensitivity, 0, 1))
    elseif event.kind == 'axis' or (event.kind == 'navigate' and (event.direction == 'left' or event.direction == 'right')) then
      local step = if event.kind == 'axis' then event.vector.x * node.props.step else (event.direction == 'right' and 1 or -1) * node.props.step
      node:emit('onChange', math.clamp(node.props.value + step, 0, 1))
    else
      base(node, event)
    end
  end,
})
```

A registration declares:

- `name`, which is unique among registrations. `registerKind` rejects a name that is already registered; `overrideKind` stacks on one. Names are namespaced by convention: the standard kinds use `lunette/`, and third-party kinds use their plugin's namespace.
- `version`, the version of the kind's interface. The interface is its props, the node state fields its visuals read, and the names of its visuals. A minor version adds only optional props, state fields, or visuals, and a major version changes or removes them. The host accepts an element built against the same major version and an equal or lower minor version, and rejects any other, so a breaking change is a visible error rather than a missing field.
- `props`, an object schema. The host rejects unknown props and validates values on every commit. The constructor's Luau type is `Props` of the schema, which makes every field read-only, adds `key` and `ref`, and adds an indexer for positional children, so the type and the runtime check have one source, and the checker rejects a misspelt prop name. Callbacks use `schema.callback`.
- `role` and `semantics`. The role comes from the closed set in the contract vocabulary, such as `button`, `toggle`, `slider`, `textbox`, `list`, `listitem`, `dialog`, or `group`. `semantics` returns the accessible name, value, range, and states such as checked, expanded, and selected. [Accessibility](accessibility.md#roles-and-semantics) describes their use.
- `layout`, which is `container` for a kind whose children the layout engine places, `leaf` with a size descriptor or a measure function for a kind that sizes itself, or `scripted` with a layout function. [Layout and text](layout-and-text.md#scripted-layout) defines them.
- `visuals`, the names of the visuals the kind draws through.
- `focus`, the focus policy: `text`, `pointer`, or `none`, as [Input](input.md#focus) defines. A `text` kind also declares its input hint. `engage` marks a value control that uses the engage mode under controller traversal.
- `captures`, how many captures the kind accepts at once. More than one enables the `transform` gesture.
- `claims`, the gestures the kind consumes, as a table or as a function evaluated when the gesture resolves. [Input](input.md#gesture-claims) defines claims. `holdDuration` sets the kind's hold duration.
- `response`, the standard interaction response that the host applies: hover lift, press travel, the state layer, the fingertip proxy's contact cue, and the feedback events for hover, press, and activation. Third-party kinds get the same feel as the standard kinds by declaring it, and a behaviour handler can adjust it through `base`.
- `motion`, the default `enter` and `exit` specs, and `cursor`, the cursor hint, as [Motion and feedback](motion-and-feedback.md) describes.
- `transform`, whether a holder of the node's handle may set its user transform. The kind itself always may.
- `event`, which receives semantic events as they bubble, as [Input](input.md#routing) describes. `node:emit` calls a prop callback under a protected call against the consumer's owner. Emitting `onChange` also raises a bubbling `change` event.
- `hit`, an optional function that replaces the default hit volume and returns a hit record, as [Spatial model](spatial-model.md#hit-volumes) describes.
- `items`, an optional function that publishes addressable items inside the node.
- `inspect`, which adds kind-specific fields to the node's inspection record.

The host rejects unknown registration fields, so a kind written against a newer host contract fails visibly on an older host rather than losing a field silently.

The registration returns a typed element constructor. The registering plugin publishes the constructor through its own service, so consumers obtain it through `context:require` and the plugin graph orders them after the registration. A constructor produces an element that names its kind, so it reaches whichever registration of that name is live at commit.

Every registration function, such as `expand`, `claims`, `hit`, `items`, `semantics`, and `inspect`, runs under a protected call. One that raises is reported against its owner, and the node falls back to a default: no expansion, no claims, its layout box as its hit volume, no items, and no semantics beyond its role.

### Items

A kind whose content is not made of nodes, such as a graph canvas with nodes and edges, a colour wheel, a pie of sectors, or a text node with links, publishes items. An item has an id, a shape from the closed set in [Spatial model](spatial-model.md#hit-volumes), an enabled state with an optional disabled reason, a role and semantics, and whether it is focusable. The host re-evaluates a node's items when its props, layout, or composed transform change, and when the poses of nodes an item depends on change. The host treats items as targets for hover, capture, focus traversal, disabled reasons, feedback, and inspection, and events carry the item id. An edge in the plugin manager's graph is therefore focusable without pointing and addressable by id in a test.

## Composite kinds

A composite kind is built from other kinds. It registers an `expand` function instead of visuals and layout:

```luau
host:registerKind(context, {
  name = 'lunette/dropdown',
  version = { major = 1, minor = 0 },
  props = dropdownProps,
  role = 'combobox',
  state = { open = false },
  expand = function(props, children, state, actions)
    return {
      button { key = 'trigger', label = selectedLabel(props), trailingIcon = 'chevron-down',
        onActivate = function() actions.setState(function(s) return { open = not s.open } end) end },
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

`expand` is framework-free: it receives the props, the children, the node's declared state, and actions, and returns host elements. `actions.setState` updates the node's state, from a table or from a function of the current state, so two updates before the next expansion do not overwrite each other. `actions.emit` calls one of the composite's own prop callbacks. Callbacks that `expand` gives to its children close over the actions, so a child's change reaches the composite. Actions on a node that has been removed do nothing. The host re-expands the composite when its props or its state change.

A composite's children are element data, passed as a prop and placed where `expand` puts them. A framework updates them by re-rendering the composite's element, not by addressing nodes inside it. Content that a composite shows only sometimes, such as a tab's page or a navigation stack's pages, goes in a content slot: a mount point that the host asks the content's framework to render only while the slot is shown. Hidden tab pages are therefore not mounted and do not subscribe to stores. A composite that needs a long list uses a virtualised kind with a host-level item renderer, `renderItem(index, key)`, which returns host elements, so a dropdown or a suggestion list over thousands of entries stays framework-free.

A child's value change also bubbles to its ancestors as a `change` event that carries the child's key and value. A composite's `event` handler can observe it, so a search field composite sees what is typed into its inner text field without the text field's handler being replaced. A `change` event from a text-input kind carries its value only to handlers and overrides whose owner is the field's effective owner, and carries no value to others.

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

A kind's event handler receives `base`, and the host exposes `overrideBehaviour(owner, kind, handler)` with the same stacking rule as visuals. A handler that calls `base` adjusts behaviour while keeping the default. Behaviour overrides apply to composite kinds through the composite's own event handler. A behaviour override cannot add props, because the props schema belongs to the kind. A behaviour change that needs new props is a kind override or a new kind.

Key and text events, and `change` events from text-input kinds, never reach a handler or override whose owner differs from the text field's effective owner, at the field or at any ancestor scope. A plugin that overrides the behaviour of a container kind therefore cannot read what a user types into a field inside it. The panel's own owner, through its kinds and shortcuts, still sees the keys typed into fields contributed to its panel, because it owns the scopes they bubble through.

An override that raises is reported against its own owner, and the node falls back to the next handler in the stack for that event.

## Kind overrides

`host:overrideKind(context, name, registration)` replaces a kind under its existing name, with the same stacking rule as visuals: the latest live override wins, and disposing it reveals the previous registration. Each node has exactly one registration responsible for it at any time.

- The override keeps the kind's major version, and its props schema is a superset of the previous registration's, which the host checks at registration. Consumers' constructors and props therefore keep working.
- The override's `expand` and `event` receive `base`, the previous registration's function, so an override can wrap the kind it replaces rather than reimplementing it, and an expansion that names the kind itself reaches the previous registration rather than recursing.
- When the live registration changes, the host recreates the kind's nodes and carries the host-owned node state across: focus, scroll offset, text and caret and selection, transforms, and captures in progress. Only state private to the registration, such as a composite's declared state, resets. Loading a theme plugin that overrides the text field kind therefore keeps what the user was typing.

A plugin that ships a different slider overrides `lunette/slider` from its own activation, requiring whatever it needs, with its errors attributed to it. Two plugins that override different kinds do not interact, and the user disables either one from the plugin manager.

## Default appearance

A session-wide switch, default appearance, renders every panel with the base registration of every kind and the base visual of every visual name, uses the base theme, and ignores every `pick` hook. Base registrations are the standard kinds, which a dedicated entry always registers, as [Replacement](#replacement) describes. The accessibility settings still apply, because they are settings rather than overrides: text scale, high contrast, reduced motion, and handedness hold in default appearance too.

Default appearance is reachable from a held controller chord, from the recovery plugin, from the wrist menu and the plugin manager, and from `lunctl`. When an override, a theme, or a replacement widget set makes the interface unusable, the user holds the chord, opens the plugin manager in its default appearance, disables or reconfigures the plugin responsible, and leaves default appearance again. Nothing in normal use is restricted. The chord and the recovery plugin are never blocked by a session-modal dialog or by pick hooks.

Inspection reports which overrides apply to each node and which owner registered them, so the manager can show the user which plugin changed what.

## Outlets

An outlet is a named, typed point in a tree where other plugins contribute subtrees. A plugin declares an outlet in its contract module through a pure function of the host contract:

```luau
local uiHost = require '@lunette-contracts/ui-host'

local settingsOutlet = uiHost.outlet {
  name = 'lunette/manager/settings',
  version = { major = 1, minor = 0 },
  props = schema.object { entry = schema.string() },
  attributed = true,
}
```

A tree places it with the host's outlet kind, `c.Outlet { outlet = settingsOutlet, props = { entry = selected } }`. Another plugin contributes to it through the host, with a mount point adapter that receives the outlet's props, or through its framework's adapter. The contribution's props type is derived from the outlet's schema:

```luau
ui.contribute(context, settingsOutlet, ui.component('BackdropSettings', function(props: schema.Output<typeof(settingsOutlet.props)>)
  if props.entry ~= 'desktop/backdrop' then return nil end
  return BackdropSettingsForm { backdrop = backdrop }
end))
```

Outlet versions follow kind versions: a minor version adds optional props, and a contribution built against an equal or lower minor version of the same major version is accepted. The host rejects a contribution whose version is incompatible, and reports the mismatch against the contributor. The host also rejects a second declaration of a name and version with a different schema. Each contribution renders under its own owner, which is the effective owner of its subtree. It is removed when its owner unloads. Each placement of an outlet is a separate instance, so an outlet shown in a wrist panel and a summoned panel at once renders each contribution twice, with separate state and effects. Contributions render in the order the outlet declares, by an ordering function or by contributor name, so a plugin's reload does not move its contributions. A contribution's error is reported against its owner and does not affect the outlet's own component.

An outlet declared `attributed` draws each contribution inside a host-drawn frame that names the contributing plugin, sized and clipped by the outlet rather than by the contribution, so a contribution cannot pass itself off as the outlet owner's own interface or push the rest of the panel out of view. The plugin manager's outlets are attributed, and they never hold the manager's own lifecycle controls.

Outlets serve custom interface. Content that the user searches, filters, groups, or reorders, such as menu actions and launcher entries, is data: the menu broker and the catalog contracts publish it, and the panel that shows it renders it, so search and grouping work across every contributor. A launcher can still offer an outlet for a contributor that needs a custom tile.

## Interaction extension

The interaction service is extended in the same way:

- A plugin can add a source or an interactor, such as a dwell interactor, a head pointer, or switch access, and it receives the same arbitration and semantic events as the standard ones. An interactor with a new shape registers that shape's query with the host, so toolkit nodes answer it. Window surfaces answer rays only.
- `interaction:registerPick(context, hook)` adds an owner-scoped `pick` hook. The latest registration is outermost: it runs first and reaches earlier hooks through `base`. Each receives the interactor and the candidates. A hook can query nodes within an angular radius of a ray that missed, so a bubble cursor or magnetic snapping can choose a target the ray did not hit. Default appearance ignores pick hooks, and the recovery plugin's surfaces bypass them.
- A plugin that drives the interface by other means, such as voice commands, resolves a node through inspection by role and name and asks the host to dispatch a semantic event to it.

## Scope of extension

| Change | Mechanism | Example |
|---|---|---|
| Appearance, broadly | Tokens and themes | A dense or high-contrast theme |
| Appearance of one kind | A visual override | A glow around the standard button, or a skeuomorphic slider |
| Appearance, beyond the primitives | A mesh with a custom material that includes the toolkit's shader code | Holographic panels or scanlines |
| Behaviour of one kind | A behaviour override | A slider that drags relative to the press point |
| One kind entirely | A kind override | A different slider |
| New widgets | `registerKind`, leaf, scripted, or composite | A knob, a colour wheel, or a timeline |
| Content in another plugin's panel | An outlet contribution | A plugin's settings page in the manager |
| Placement | A registered presentation | A follow presentation for toasts, or a palm-up hand menu |
| Surfaces | A registered shape | A forearm cylinder or a sphere patch |
| Input | A source, an interactor, or a `pick` hook | Dwell, gaze with pinch, switch access, or a bubble cursor |
| The whole widget set | A replacement provider of `lunette/ui-components` | A different design language |
| Everything | A replacement provider of `lunette/ui-host` | A different toolkit behind the same contract |

The host has no pluggable renderer, material system, or layout engine. A custom appearance beyond the drawing API's primitives uses the mesh slot, and a whole different renderer is a replacement host.

## Replacement

The standard kinds and their default visuals are registered by a dedicated entry, `ui/standard`, which provides `lunette/ui-standard-kinds`. They are the base of every kind's override stack, and default appearance uses them. The components plugin, which provides `lunette/ui-components`, publishes the typed constructors that consumers use and can register kind and visual overrides of its own.

- Replacing the components plugin with an entry patch replaces the design language. A replacement provides `lunette/ui-components` with the same props types from `ui-components.luau`, and registers kind and visual overrides above the standard kinds rather than registering the kinds again. Consumers keep working, and default appearance still has the standard kinds to fall back to.
- Replacing one kind is a kind override from any plugin, not a configuration change.
- Replacing the host replaces drawing, hit testing, layout synchronisation, and composite expansion. A replacement implements `lunette/ui-host` and preserves the guarantees in the host contract.

## Other frameworks

An authoring framework is a library that binds mount points and produces host elements for them. The React-like library is one. A signals library or an immediate-mode library binds mount points through the same adapter, produces the same elements through the same node change API, and contributes to outlets through its own adapter.

Panels built with different frameworks use the same kinds, composites, visuals, theme, focus traversal, and inspection. A framework with different sensibilities therefore changes how authors write UI, not how the UI looks or behaves.

## Contract evolution

The plugin runtime matches contracts by exact name and version, and a capability has one active provider. The host and components contracts therefore change in two ways:

- An additive change, such as a new optional event field, a new drawing primitive, a new optional registration field, a new standard kind, or a new optional prop on a standard kind, keeps the capability's version. The host and components services each publish a feature set, and kinds publish minor versions, so a kind, framework, or consumer that needs a feature asserts it at activation. A newer plugin on an older or replacement provider then fails at activation with a named missing feature rather than at the point of use.
- A breaking change, such as renaming a node state field or changing an event's shape, bumps the capability's version, and every kind, visual, and framework moves with it. Breaking changes are therefore batched, and feature sets and minor versions cover additions between them.

The node interface that visuals and behaviour overrides read is declared as types in `ui-host.luau`, so a breaking change appears as a type error in every override rather than as a `nil` at draw time.

## Trust

The plugin runtime is not a security boundary, and the toolkit inherits that. Every plugin runs with the session's privileges, and the toolkit does not attempt to contain a hostile plugin. It does limit what a faulty or careless plugin can do by accident, keeps the user able to undo it, and makes the origin of every part of the interface visible:

- Text-input events and values reach no handler or override from another owner, at the field or at any ancestor.
- Attributed outlets name the contributing plugin and bound the contribution's size.
- Default appearance reverts every override, theme, replacement widget set, and pick hook for as long as it is on, and the chord that enables it cannot be blocked.
- Session-modal dialogs never block the chord, the recovery plugin, or window panels.
- Inspection records the owner of every panel, node, contribution, and override.

A plugin that places a panel over another plugin's interface, draws a convincing imitation of another plugin's interface, or reads another plugin's state through its services is not prevented. The user's protection against such a plugin is not installing it.
