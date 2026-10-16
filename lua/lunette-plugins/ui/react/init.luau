-- The React-like authoring library: function components with hooks, rendered into host elements on a panel's
-- mount point. It is a library: it registers no services, and everything it holds belongs to the mounted panel.

local uiHost = require '@lunette-contracts/ui-host'
local protected = require '@lunette-plugins/diagnostics/protected-call'
local vocabulary = require '@lunette-contracts/vocabulary'
local instances = require '@self/private/instances'

local ui = {}

export type Element = uiHost.Element
export type Child = uiHost.Child | instances.ComponentElement
export type Children = { read [number]: Child }
export type Context<T> = { default: T, id: number }
export type Ref<T> = { current: T }

export type Store<T> = vocabulary.Store<T>

export type WritableStore<T> = Store<T> & {
  read set: (WritableStore<T>, T) -> (),
}

export type MountHandle = {
  read committed: (MountHandle) -> boolean,
  read unmount: (MountHandle) -> (),
}

export type MountOptions = {
  read components: any?,
  -- The owner that effects receive, for resources they acquire through services.
  read owner: any?,
}

local componentsContext = instances.newContext(nil)

-- Declares a component. The constructor takes one table: named fields are props, array entries are children.
function ui.component<P>(name: string, render: (props: P) -> any): (props: any?) -> Child
  assert(type(name) == 'string' and name ~= '', 'ui: a component has a name')
  assert(type(render) == 'function', `ui: the component {name} renders with a function`)
  local definition: instances.Definition = { name = name, render = render :: any }
  return function(given: any?): Child
    local props: { [string]: any } = {}
    local key: string? = nil
    if given then
      for field, value in given do
        if field == 'key' then
          key = tostring(value)
        elseif type(field) == 'string' then
          props[field] = value
        end
      end
      local children = {}
      local count = 0
      for index in given do
        if type(index) == 'number' and index > count then
          count = index
        end
      end
      for index = 1, count do
        children[index] = given[index]
      end
      if count > 0 then
        props.children = children
      end
    end
    local element: instances.ComponentElement = {
      kind = instances.COMPONENT,
      component = definition,
      key = key,
      props = props,
    }
    return element :: any
  end
end

-- Mounts an element on a panel's root mount point. The first render happens at the panel's next commit.
function ui.mount(panel: uiHost.Panel, element: Child, options: MountOptions?): MountHandle
  local mount = panel.root
  local given: MountOptions = options or { components = nil, owner = nil }
  local root: instances.Root = {
    schedule = function(): ()
      mount:schedule()
    end,
    report = function(label: string, run: () -> ()): ()
      protected.call(label, run)
    end,
    owner = given.owner,
    effects = {},
    rendering = nil,
    hookIndex = 0,
  }
  local top = instances.new(root, {
    name = 'root',
    render = function(): any
      return ui.provide(componentsContext, given.components, element)
    end,
  }, {}, nil, nil)
  local unmounted = false
  mount:bind {
    render = function(): ()
      if unmounted then
        mount:submit(nil)
        return
      end
      local previous = instances.current
      instances.current = root
      local ok, output = pcall(instances.resolve, top)
      instances.current = previous
      if not ok then
        error(output, 0)
      end
      assert(#output <= 1, `ui: the mounted element resolved to {#output} elements; a panel takes one`)
      mount:submit(output[1])
      local effects = root.effects
      root.effects = {}
      for _, effect in effects do
        protected.call('ui: effect', effect)
      end
    end,
    unmount = function(): ()
      instances.unmount(top)
    end,
  }
  return {
    committed = function(_self: MountHandle): boolean
      return mount:committed()
    end,
    unmount = function(_self: MountHandle): ()
      if not unmounted then
        unmounted = true
        instances.unmount(top)
        mount:schedule()
      end
    end,
  }
end

function ui.createContext<T>(default: T): Context<T>
  return instances.newContext(default) :: any
end

local providers: { [number]: instances.Definition } = {}

-- Provides a context value to the children's subtree.
function ui.provide<T>(context: Context<T>, value: T, children: Child): Child
  local definition = providers[context.id]
  if not definition then
    local created: instances.Definition = {
      name = 'Provider',
      context = context :: any,
      render = function(props: any): any
        local hook = instances.hook('provider', function(): instances.Hook
          return { value = props.value, subscribers = setmetatable({}, { __mode = 'k' }) }
        end)
        if hook.value ~= props.value then
          hook.value = props.value
          for subscriber in hook.subscribers do
            instances.invalidate(subscriber)
          end
        end
        return props.children
      end,
    }
    providers[context.id] = created
    definition = created
  end
  local element: instances.ComponentElement = {
    kind = instances.COMPONENT,
    component = definition,
    key = nil,
    props = { value = value, children = children },
  }
  return element :: any
end

function ui.useContext<T>(context: Context<T>): T
  local _, instance = instances.hook('context', function(): instances.Hook
    return {}
  end)
  local current = instance.parent
  while current do
    if current.definition.context == (context :: any) then
      local provider = current.hooks[1]
      if provider then
        provider.subscribers[instance] = true
      end
      return current.props.value
    end
    current = current.parent
  end
  return context.default
end

-- The standard kinds' constructors, as the mount provided them.
function ui.useComponents(): any
  return ui.useContext(componentsContext :: any)
end

function ui.useState<T>(initial: T | () -> T): (T, (T | (T) -> T) -> ())
  local hook, instance = instances.hook('state', function(): instances.Hook
    local value = if type(initial) == 'function' then (initial :: () -> T)() else initial
    return { value = value }
  end)
  if not hook.set then
    hook.set = function(next: any): ()
      local value = if type(next) == 'function' then (next :: (any) -> any)(hook.value) else next
      if value ~= hook.value then
        hook.value = value
        instances.invalidate(instance)
      end
    end
  end
  return hook.value, hook.set
end

local function changed(previous: { any }?, dependencies: { any }?): boolean
  if previous == nil or dependencies == nil then
    return true
  end
  if #previous ~= #dependencies then
    return true
  end
  for index, value in dependencies do
    if previous[index] ~= value then
      return true
    end
  end
  return false
end

function ui.useMemo<T>(compute: () -> T, dependencies: { any }?): T
  local hook = instances.hook('memo', function(): instances.Hook
    return { primed = false }
  end)
  if not hook.primed or changed(hook.dependencies, dependencies) then
    hook.primed = true
    hook.value = compute()
    hook.dependencies = dependencies and table.clone(dependencies)
  end
  return hook.value
end

function ui.useRef<T>(initial: T): Ref<T>
  local hook = instances.hook('ref', function(): instances.Hook
    return { ref = { current = initial } }
  end)
  return hook.ref
end

-- Runs the effect after the render pass is submitted when a dependency changes. The cleanup it returns runs before
-- the next run and on unmount. The effect receives the mount's owner.
function ui.useEffect(effect: (owner: any) -> (() -> ())?, dependencies: { any }?): ()
  local hook, instance = instances.hook('effect', function(): instances.Hook
    return { primed = false }
  end)
  if hook.primed and not changed(hook.dependencies, dependencies) then
    return
  end
  hook.primed = true
  hook.dependencies = dependencies and table.clone(dependencies)
  table.insert(instance.root.effects, function(): ()
    if not instance.mounted then
      return
    end
    local cleanup = hook.cleanup
    hook.cleanup = nil
    if type(cleanup) == 'function' then
      (cleanup :: () -> ())()
    end
    hook.cleanup = effect(instance.root.owner)
  end)
end

-- Layout effects run with the other effects in this version, after the render pass and before the next commit.
ui.useLayoutEffect = ui.useEffect

-- Reads a store and re-renders the component when it changes.
function ui.useStore<T>(store: Store<T>): T
  local hook, instance = instances.hook('store', function(): instances.Hook
    return {}
  end)
  if hook.store ~= store then
    local previous = hook.cleanup
    if type(previous) == 'function' then
      (previous :: () -> ())()
    end
    hook.store = store
    hook.cleanup = store:subscribe(function(): ()
      instances.invalidate(instance)
    end)
  end
  return store:get()
end

-- Maps a list to keyed children. Every child needs a key, and keys are unique.
function ui.map<T>(list: { read [number]: T }, render: (T, number) -> Child): Children
  local result: { Child } = {}
  local seen: { [string]: boolean } = {}
  for index, item in list do
    local child = render(item, index)
    if child then
      local key = (child :: any).key
      assert(key ~= nil, `ui: the child at index {index} of a mapped list has no key`)
      assert(not seen[key], `ui: two children of a mapped list share the key '{key}'`)
      seen[key] = true
    end
    result[index] = child
  end
  return result
end

-- A writable store. Subscribers run when `set` changes the value.
function ui.store<T>(initial: T): WritableStore<T>
  local value = initial
  local subscribers: { (T) -> () } = {}
  local store = {}
  function store.get(_self: any): T
    return value
  end
  function store.set(_self: any, next: T): ()
    if next == value then
      return
    end
    value = next
    for _, subscriber in table.clone(subscribers) do
      subscriber(value)
    end
  end
  function store.subscribe(_self: any, subscriber: (T) -> ()): () -> ()
    table.insert(subscribers, subscriber)
    return function(): ()
      local index = table.find(subscribers, subscriber)
      if index then
        table.remove(subscribers, index)
      end
    end
  end
  return store :: any
end

return ui
