# Authoring

Plugin authors write function components in the style of React. A component receives props and returns elements. The library re-runs a component when its state, its props, its context, or a store it reads changes, reconciles the new elements against the previous ones by key, and sends the differences to the host as element changes.

The library is one authoring framework among possible others. It produces host elements, as [Extension](extension.md#the-element-format) defines, and nothing in the host depends on it.

## An example

The backdrop controls, written as a component:

```luau
local ui = require '@lunette-plugins/ui/react'

local intensity = { { value = 0, label = 'None' }, { value = 0.25, label = 'Low' }, { value = 0.5, label = 'Medium' },
  { value = 0.75, label = 'High' }, { value = 1, label = 'Full' } }

local BackdropControls = ui.component('BackdropControls', function(props: { backdrop: backdrop.Service })
  local c = ui.useComponents()
  local settings = ui.useStore(props.backdrop.settings)
  local applications = ui.useStore(props.backdrop.applications)

  local pinReason = if settings.source ~= 'attention' then 'Pinning is available with the Attention source.' else nil

  return c.Column { gap = 'md', padding = 'lg',
    c.Toggle { key = 'enabled', label = 'Backdrop', value = settings.enabled,
      onChange = function(enabled) props.backdrop:setEnabled(enabled) end },
    c.Segmented { key = 'source', label = 'Audio source', value = settings.source,
      options = { { id = 'mix', label = 'System mix' }, { id = 'pinned', label = 'Pinned' }, { id = 'attention', label = 'Attention' } },
      onChange = function(source) props.backdrop:setSource(source) end },
    c.Button { key = 'pin', label = 'Pin the attended application', disabledReason = pinReason,
      onActivate = function() props.backdrop:pinAttended() end },
    c.Section { key = 'applications', title = 'Applications',
      ui.map(applications, function(application)
        return c.ListRow { key = application.id, title = application.title,
          detail = `{application.appId} · #{application.pid}`, trailing = application.audioState }
      end),
    },
    c.Slider { key = 'response', label = 'Response', min = 0, max = 1, value = settings.response, detents = intensity,
      onChange = function(response) props.backdrop:setResponse(response) end },
    c.Slider { key = 'motion', label = 'Motion', min = 0, max = 1, value = settings.motion, detents = intensity,
      onChange = function(motion) props.backdrop:setMotion(motion) end },
    if settings.diagnostics then c.Text { key = 'status', style = 'caption', text = settings.status } else nil,
  }
end)
```

The consumer mounts it on a panel it owns:

```luau
local panel = host:newPanel(context, { name = 'Backdrop', presentation = host.presentations.world, size = 'content' })
ui.mount(panel, BackdropControls { backdrop = backdrop }, { components = components })
```

The example shows the properties the model is chosen for. Conditional content is a plain `if` expression. Lists are a plain mapping with keys. Derived values such as `pinReason` are plain locals. The disabled reason is a prop rather than text in a label. The component reads services through stores, so nothing polls or re-sets values each frame. A slider's detents are snap points with labels and a feedback tick, so a continuous value keeps named levels.

## Mounting

`ui.mount(panel, element, options)` binds the panel's root mount point and schedules the element's first render. The render is committed at the next commit, never inside the call, so mounting behaves the same during activation, during an event dispatch, and from an effect. The mount handle's `committed` callback runs after the first commit, for a consumer that needs the panel's content size or inspection records at once.

## Elements and children

An element constructor takes one table. Named fields are props. Array entries are children. Children can be elements, arrays of elements, `nil`, or `false`. A `nil` or `false` child renders nothing but keeps its position, and an array is flattened in place as its own key scope, so `ui.map` and conditional expressions compose without wrapper elements, and an error message that appears above a field does not shift the field's position. The library iterates numeric keys up to the largest one, and does not rely on `#`, because a `nil` child leaves a hole in the array.

The children type is a read-only indexer, `ui.Children = { read [number]: ui.Child }`, so that an array of elements returned by `ui.map` satisfies it. A read-write array type is compared invariantly and would reject that array.

`key` identifies an element among its siblings. Elements in an array returned by `ui.map` require keys, and the library raises when one is missing or duplicated. Other children are keyed by position when they have no key, and because `nil` holds its position, a positional key is stable while the component's structure is. A key also forms the element's id for inspection and tests, as [Testing](testing.md#ids-and-inspection) describes, so anything a test or a caller addresses has an explicit key.

Each kind's constructor is typed. Its props type is `Props` of the kind's props schema, from `ui-host.luau`, which makes every field read-only, so a component can pass a narrower table, and adds `key`, `ref`, and the children indexer. Token-valued props accept a token name or a number. The checker rejects a wrong value type and a misspelt prop name, because the children indexer only accepts numeric keys. The host also rejects unknown props on every commit, so an element built without the types is checked too.

## Components

A component is a function from props to an element, an array of elements, or `nil`. A component is declared with `ui.component`, which takes a name for error messages and inspection:

```luau
local SettingRow = ui.component('SettingRow', function(props: { label: string, detail: string?, children: ui.Children })
  local c = ui.useComponents()
  return c.Row { gap = 'sm', align = 'center',
    c.Column { grow = 1, c.Text { text = props.label }, if props.detail then c.Text { style = 'caption', text = props.detail } else nil },
    props.children,
  }
end)
```

`ui.component` returns a constructor with the same calling convention as a kind's constructor. A component re-renders when its parent re-renders with props that differ shallowly from the previous props, when its own state changes, when a context it reads changes, or when a store it reads changes.

Shallow comparison ignores function-valued props. A function prop is compared only by being a function, and the node calls the latest one, so an inline `onChange = function ... end` does not make a child re-render. Shallow comparison is the default because function components without it re-render their whole subtree on every parent render, and that cost grows with the tree. A table literal prop, such as `options` in the example, is a new table on each render and does defeat the comparison. A component that renders often keeps such tables in a module-level local or in `ui.useMemo`.

## Hooks

- `ui.useState(initial)` returns the current value and a setter. Setting a value equal to the current value does not schedule a render.
- `ui.useStore(store)` reads an observable store and re-renders the component when the store changes.
- `ui.useContext(context)` reads a value that an ancestor provides through `ui.provide(context, value, children)`. `ui.useComponents()` is the context for the standard constructors.
- `ui.useEffect(effect, dependencies)` runs `effect` after commit when a dependency changes. The cleanup that `effect` returns runs before the next run and on unmount. `effect` receives the subtree's effective owner, so a resource acquired through a service belongs to an owner as the plugin runtime requires, and the cleanup releases it when the component unmounts.
- `ui.useLayoutEffect(effect, dependencies)` runs after layout and pose computation and before draw, in the same frame. It reads node poses and bounds through refs, and a state change it makes renders and commits once more in the same frame. Wires between ports, drop indicators, and toolbars that overflow into a menu use it, so they do not lag a frame behind layout.
- `ui.useMemo(compute, dependencies)` caches a derived value.
- `ui.useRef(initial)` returns a stable mutable table. Passed as the `ref` prop of an element, it receives the node handle.
- `ui.usePresentation()` returns the panel's presentation and its density, as [Presentations](presentations.md#adapting-content) describes.

The node handle provides `pose()`, `bounds()`, `focus()`, `scrollIntoView()`, `scrollTo(offset)`, `scrollBy(delta)`, `setTransform(transform)`, and `animate(channel, target, role)`. It is the same node interface that kinds receive, restricted to reading and to these requests.

Hooks are identified by call order within a component, as in React. A hook called conditionally, or a different number of hooks between renders, makes the library raise with the component's name. Luau cannot check call order statically, so this is a runtime check. A render that raises rolls the component's hook state back to its previous successful render.

## Stores

A store is an observable value with `get` and `subscribe`, and a writable store adds `set`. The contract vocabulary defines the read-only store type so that services can expose state without importing the library. `useStore` subscribes on the subtree's effective owner and unsubscribes when the component unmounts.

Stores are a requirement on services as well as on the toolkit. A service whose state a panel shows publishes that state as stores, so that no consumer polls. A service that accepts requests whose outcome arrives later, such as launching an application or creating a monitor mirror, publishes the request's progress as a store.

## Scheduling

State changes schedule renders on the component's mount point. Renders run in the host's commit steps, before keyboard input, before picking, and after input delivery, as [Architecture](architecture.md#data-flow) describes. Several changes in one frame cause one render of each affected component per commit step. A render never runs during another component's render or during drawing.

A store changed by a service outside the frame loop, such as a compositor event, schedules renders for the next commit step in the same way.

## Transient state

Hover, press, drag position, focus, scroll offset, transforms, the open state of a dropdown, the caret of a text field, and animation channels belong to nodes. They change without rendering any component. A component that needs to react to one of them uses a prop callback, such as `onOpenChange` on a dropdown, and keeps its own copy in state.

## Controlled values

A controlled value, such as a toggle's or a slider's `value`, is owned by the component. A controlled kind shows the user's new value in the frame whose input produced it, before the component's `value` changes:

- During a drag, the dragged value wins over the `value` prop. A prop update during the drag, such as a media position that advances while the user scrubs, does not move the thumb.
- `onChange` reports each new value, and `onCommit` reports the final value on release.
- After the user's change, the kind keeps showing the new value until `value` changes. If the first commit after the release leaves `value` unchanged, the kind returns to `value`.

A component therefore never sees a control flicker back for a frame while a service applies the change asynchronously.

## Reload

Source reload discards component state, as it discards all plugin state. The consumer mounts its component again during activation, and the tree renders from scratch. Panel placement survives reload through the arrangement service, not through component state.

## Comparison with other models

Signals in the style of Vide and Fusion run a component once and attach reactivity to closures. They make updates precise, but conditional content needs `show` and `switch` helpers, lists need `indexes` with accessor items, and a store read outside a reactive closure silently loses its reactivity. Plain Lua control flow inside a component is worth more to plugin authors than the precision of signals, and the toolkit's trees are small enough that render cost is not the constraint. Stores provide the observable half of signals where services need it. A signals framework can still target the host, as [Extension](extension.md#other-frameworks) describes.

Immediate mode in the style of Dear ImGui, StereoKit, and lovr-ui re-declares the interface every frame and derives ids from call sites or labels. It suits small tools and is easy to start with, but it re-runs every widget's logic every frame, derives identity from labels or call order, and sizes content one frame late. Dense session interfaces with scrolling, virtualised lists, overlays, and focus traversal need retained nodes with stable identity.

A virtual DOM that diffs the whole tree every frame is not used. Rendering happens only on change, and only for the components that changed.

[Research](research.md#authoring-models) describes each system in more detail.
