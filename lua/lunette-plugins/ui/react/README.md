# React-like library

`@lunette-plugins/ui/react` renders function components into host elements on a panel's mount point. It is a library: it registers no services, and component state belongs to the mounted panel. [Authoring](../../../../docs/development/ui/authoring.md) specifies the model.

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

`ui.useStore` reads during render and subscribes after successful submission. A failed render keeps the previous subscription. A store change between the read and subscription schedules another render, and unmounting releases the subscription.

`ui.createContext` returns a context whose identity distinguishes it from other contexts with the same default. Provider values belong to each mounted subtree. Contexts have no public numeric identifier.

`ui.contribute(context, outlet, component, options)` contributes a component to an [outlet](../../../lunette-contracts/ui-host.luau) for the context's lifetime. The host renders it once for each placement, with the placement's props as the component's props and separate state and effects, and the library reports the component's errors against the contributing plugin. `options.components` provides the standard constructors to `useComponents`, and `options.version` names the outlet version the component is built against when it differs from the declaration.
