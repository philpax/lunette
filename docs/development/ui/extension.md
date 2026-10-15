# Extension

The toolkit extends through the plugin runtime's existing mechanisms: owner-scoped registrations, shared-value overrides, hooks that receive `base`, and entry patches. Every extension point is public, and the standard widgets use the same points as third-party plugins. A capability that a standard widget needs and a third-party widget cannot reach is a defect in the host contract.

## Element kinds

An element kind is registered on the host with an owner:

```luau
local knob = host:registerKind(context, {
  name = 'example/knob',
  props = knobSchema,
  layout = { kind = 'leaf', measure = function(props, availableWidth, availableHeight) return 0.04, 0.04 end },
  visuals = { 'example/knob' },
  focusable = true,
  event = function(node, event, base)
    if event.kind == 'drag' then
      node:emit('onChange', node.props.value + event.dy * node.props.sensitivity)
    end
  end,
  inspect = function(node) return { value = node.props.value } end,
})
```

A registration declares:

- `name`, which is unique among live kinds. Names are namespaced by convention: the standard kinds use `lunette/`, and third-party kinds use their plugin's namespace.
- `props`, a schema that the host validates on every commit in development builds and on mount in all builds.
- `layout`, which is `container` for a kind whose children the native layout positions, or `leaf` with a measure function for a kind that sizes itself. A leaf measure function receives the available width and height in metres, either of which can be `nil` when unconstrained, and returns the intrinsic width and height. Text measurement never passes through a Lua measure function; [Layout and text](layout-and-text.md#measurement) explains why.
- `visuals`, the names of the visuals the kind draws through.
- `focusable`, and whether the kind takes text input and therefore summons the virtual keyboard.
- `event`, which receives semantic events. `node:emit` calls a prop callback under a protected call against the consumer's owner.
- `inspect`, which adds kind-specific fields to the node's inspection record.

The registration returns a typed element constructor. The registering plugin publishes the constructor through its own service, so consumers obtain it through `context:require` and the plugin graph orders them after the registration.

A kind can also be composite: a component registered under a kind name, built from other kinds. Composite kinds need no layout, visual, or event code. The dropdown, for example, is a composite of a button, an overlay, and a list.

## Visuals

A visual draws a node's appearance with the host's drawing API, which applies the node's clip, elevation, and curvature. [Rendering](rendering.md#drawing-api) describes the API. A visual receives the node, the drawing API, and `base`:

```luau
host:overrideVisual(context, 'lunette/button', function(node, draw, base)
  base(node, draw)
  if node.state.focused then
    draw:ring(node.bounds, { width = 0.002, color = node.theme.colors.focus, radius = node.theme.radii.control })
  end
end)
```

Calling `base` keeps the previous visual and adds to it. Omitting it replaces the appearance. The latest live override wins, and disposing it reveals the previous one, which is the plugin runtime's rule for shared-value overrides. An override cannot change hit geometry, layout, or behaviour. Those belong to the kind.

A theme plugin that wants a different visual language registers overrides for the visuals it changes. Colours, spacing, type, radii, and elevation come from tokens, so most restyling needs no visual override. [Theming](theming.md) describes tokens.

## Behaviour hooks

A kind's event handler receives `base`, and the host exposes `overrideBehaviour(owner, kind, handler)` with the same override rule as visuals. A handler that calls `base` adjusts behaviour while keeping the default. A behaviour override cannot add props, because the props schema belongs to the kind. A behaviour change that needs new props is a new kind, usually a composite.

## Outlets

An outlet is a named point in a tree where other plugins contribute subtrees. A component declares an outlet:

```luau
c.Section { key = 'plugin-settings', title = 'Settings', ui.outlet('lunette/manager/settings', { entry = selected }) }
```

Another plugin contributes to it:

```luau
host:contribute(context, 'lunette/manager/settings', function(props)
  if props.entry ~= 'desktop/backdrop' then return nil end
  return BackdropSettings { backdrop = backdrop }
end)
```

Each contribution is a component. It receives the outlet's props, renders under its own owner, and is removed when its owner unloads. Contributions render in registration order unless the outlet declares an ordering prop. A contribution's error is reported against its owner and does not affect the outlet's own component.

Outlets let a plugin contribute UI where a broker would contribute only data. The wrist menu exposes an outlet for launcher tiles, and the plugin manager exposes one for per-plugin settings pages.

## Replacement

A configuration replaces any layer with an entry patch.

- Replacing the standard components plugin replaces every standard kind. A replacement provides the same `lunette/ui-components` capability and the same constructor types, so consumers keep working.
- Replacing the host replaces drawing, hit testing, and layout synchronisation. A replacement implements `lunette/ui-host` and preserves the guarantees in the host contract.
- Replacing a single kind uses a registration with the same name after the standard components plugin unloads it, or a fork of the standard components plugin. Two live registrations of one kind name are rejected, because a node's behaviour must have one owner.

## Other frameworks

An authoring framework is a library that produces node changes for a panel. The React-like library is one. A signals library or an immediate-mode library can produce the same changes: create a node of a kind with props, update its props, move it, and remove it. The host provides this node change API publicly for that purpose.

Panels built with different frameworks use the same kinds, visuals, theme, focus traversal, and inspection. One panel can mix frameworks through an element that mounts a subtree from another framework, because both sides produce nodes for the same host. A framework with different sensibilities therefore changes how authors write UI, not how the UI looks or behaves.
