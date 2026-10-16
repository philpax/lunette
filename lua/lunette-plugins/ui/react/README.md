# React-like library

`@lunette-plugins/ui/react` renders function components into host elements on a panel's mount point. It is a library: it registers no services, and the state it holds belongs to the mounted panel. [Authoring](../../../../docs/development/ui/authoring.md) specifies the model.

```luau
local ui = require '@lunette-plugins/ui/react'

local Counter = ui.component('Counter', function(props: { label: string })
  local c = ui.useComponents()
  local count, setCount = ui.useState(0)
  return c.Button { label = `{props.label} {count}`, onActivate = function() setCount(count + 1) end }
end)

ui.mount(panel, Counter { label = 'Pressed' }, { components = components, owner = context })
```

Components re-render when their state, a store or context they read, or their shallowly compared props change. Function props compare equal. Hooks are `useState`, `useMemo`, `useRef`, `useEffect`, `useStore`, `useContext`, and `useComponents`; `useLayoutEffect` runs with the other effects in this version. `ui.map` requires a unique key for each child, and `ui.store` creates a writable store.
