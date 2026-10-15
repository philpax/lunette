# Authoring

Plugin authors write function components in the style of React. A component receives props and returns elements. The library re-runs a component when its state, its props, or a store it reads changes, reconciles the new elements against the previous ones by key, and sends the differences to the host as node changes.

## An example

The backdrop controls, written as a component:

```luau
local ui = require '@lunette-plugins/ui/react'

local function BackdropControls(props: { backdrop: backdrop.Service, c: components.Service })
  local c = props.c
  local settings = ui.useStore(props.backdrop.settings)
  local applications = ui.useStore(props.backdrop.applications)

  local pinReason = if settings.source ~= 'attention' then 'Available with the Attention source' else nil

  return c.Column { gap = 'md', padding = 'lg',
    c.Toggle { key = 'enabled', label = 'Backdrop', value = settings.enabled,
      onChange = function(enabled) props.backdrop:setEnabled(enabled) end },
    c.Toggle { key = 'audio', label = 'Audio reactivity', value = settings.audio,
      onChange = function(audio) props.backdrop:setAudio(audio) end },
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
    c.Slider { key = 'response', label = 'Response', min = 0, max = 1, value = settings.response,
      onChange = function(response) props.backdrop:setResponse(response) end },
    if settings.diagnostics then c.Text { key = 'status', style = 'caption', text = settings.status } else nil,
  }
end
```

The consumer mounts it on a panel it owns:

```luau
local panel = host:newPanel(context, { name = 'Backdrop', presentation = 'world', size = 'content' })
ui.mount(panel, BackdropControls, { backdrop = backdrop, c = components })
```

The example shows the properties the model is chosen for. Conditional content is a plain `if` expression. Lists are a plain mapping with keys. Derived values such as `pinReason` are plain locals. The disabled reason is a prop rather than text in a label. The component reads services through stores, so nothing polls or re-sets values each frame.

## Elements and children

An element constructor takes one table. Named fields are props. Array entries are children. Children can be elements, arrays of elements, `nil`, or `false`. The library skips `nil` and `false`, and flattens arrays, so `ui.map` and conditional expressions compose without wrapper elements. The library iterates numeric keys up to the largest one, and does not rely on `#`, because a `nil` child leaves a hole in the array.

`key` identifies an element among its siblings. Elements in an array returned by `ui.map` require keys, and the library raises when one is missing or duplicated. Other children are keyed by position when they have no key. A key also forms the element's id for inspection and tests, as [Testing](testing.md) describes, so stable keys are required for anything a test addresses.

Each kind's constructor is typed. `c.Slider` accepts `SliderProps`, and the checker rejects a misspelt prop or a wrong value type. Props are declared as `read` fields so that a component can pass a narrower table.

## Components

A component is a function from props to an element, an array of elements, or `nil`. A component is invoked through `ui.component`:

```luau
local SettingRow = ui.component(function(props: { label: string, detail: string?, children: ui.Children })
  return c.Row { gap = 'sm', align = 'center',
    c.Column { grow = 1, c.Text { text = props.label }, if props.detail then c.Text { style = 'caption', text = props.detail } else nil },
    props.children,
  }
end)
```

`ui.component` returns a constructor with the same calling convention as a kind's constructor. A component re-renders when its parent re-renders with props that differ shallowly from the previous props, when its own state changes, or when a store it reads changes. Shallow comparison is the default because function components without it re-render their whole subtree on every parent render, and that cost grows with the tree.

## Hooks

The hook set is deliberately small.

- `ui.useState(initial)` returns the current value and a setter. Setting a value equal to the current value does not schedule a render.
- `ui.useStore(store)` reads an observable store and re-renders the component when the store changes.
- `ui.useEffect(effect, dependencies)` runs `effect` after commit when a dependency changes. The cleanup that `effect` returns runs before the next run and on unmount. Effects receive the panel's owner, so a resource acquired in an effect belongs to an owner as the plugin runtime requires.
- `ui.useMemo(compute, dependencies)` caches a derived value.
- `ui.useRef(initial)` returns a stable mutable table, and a node handle when passed as the `ref` prop of an element.

Hooks are identified by call order within a component, as in React. A hook called conditionally, or a different number of hooks between renders, makes the library raise with the component's name. Luau cannot check call order statically, so this is a runtime check.

## Stores

A store is an observable value with `get`, `set`, and `subscribe`. The contract vocabulary defines the read-only store type so that services can expose state without importing the library. A service that a UI shows exposes its state as stores, and `useStore` subscribes to them with the component's owner.

Stores are a requirement on services as well as on the toolkit. A service whose state a panel shows publishes that state as stores, so that no consumer polls.

## Scheduling

State changes schedule renders, and renders run once per frame in the update phase, after input and before layout. Several changes in one frame cause one render of each affected component. A render never runs during another component's render or during drawing.

A store changed by a service outside the frame loop, such as a compositor event, schedules renders for the next frame in the same way.

## Transient state

Hover, press, drag position, focus, scroll offset, the open state of a dropdown, the caret of a text field, and animation progress belong to nodes. They change without rendering any component. A component that needs to react to one of them uses a prop callback, such as `onOpenChange` on a dropdown, and keeps its own copy in state.

A controlled value, such as a slider's `value`, is owned by the component. During a drag the slider node shows the dragged value immediately and calls `onChange`. If the component does not update `value` in response, the node returns to the component's value when the drag ends.

## Reload

Source reload discards component state, as it discards all plugin state. The consumer mounts its component again during activation, and the tree renders from scratch. Panel placement survives reload through the arrangement service, not through component state.

## Comparison with other models

Signals in the style of Vide and Fusion run a component once and attach reactivity to closures. They make updates precise, but conditional content needs `show` and `switch` helpers, lists need `indexes` with accessor items, and a store read outside a reactive closure silently loses its reactivity. Plain Lua control flow inside a component is worth more to plugin authors than the precision of signals, and the toolkit's trees are small enough that render cost is not the constraint. Stores provide the observable half of signals where services need it.

Immediate mode in the style of Dear ImGui, StereoKit, and lovr-ui re-declares the interface every frame and derives ids from call sites or labels. It suits small tools and is easy to start with, but it re-runs every widget's logic every frame, derives identity from labels or call order, and sizes content one frame late. Dense session interfaces with scrolling, virtualised lists, overlays, and focus traversal need retained nodes with stable identity.

A virtual DOM that diffs the whole tree every frame is not used. Rendering happens only on change, and only for the components that changed.

[Research](research.md#authoring-models) describes each system in more detail.
