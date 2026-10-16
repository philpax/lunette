-- Component instances: rendering components into host elements, hook storage, and reuse of unchanged output.
-- An instance re-renders when it is dirty or its props changed shallowly. An ancestor of a dirty instance is stale:
-- it re-resolves its last rendered elements, reusing every unchanged child's output, without running its render.

local uiHost = require '@lunette-contracts/ui-host'

local instances = {}

export type Hook = { [string]: any }

export type Definition = {
  name: string,
  render: (props: any) -> any,
  -- Provider components carry a context value to their descendants.
  context: Context?,
}

export type Context = { default: any, id: number }

-- A component element: library data that never reaches the host.
export type ComponentElement = {
  kind: string,
  component: Definition,
  key: string?,
  props: { [string]: any },
}

export type Instance = {
  definition: Definition,
  key: string?,
  props: { [string]: any },
  parent: Instance?,
  hooks: { Hook },
  -- The elements the last render returned, before resolving nested components.
  rendered: any,
  -- The host elements the instance resolved to.
  output: { uiHost.Element },
  children: { [string]: Instance },
  -- Stable functions that forward to the latest function props, by prop name.
  forwards: { [string]: (...any) -> ...any },
  contexts: { [number]: any },
  dirty: boolean,
  stale: boolean,
  mounted: boolean,
  root: Root,
}

export type Root = {
  schedule: () -> (),
  report: (string, () -> ()) -> (),
  owner: any,
  -- Effects to run once the current render pass has been submitted.
  effects: { () -> () },
  rendering: Instance?,
  hookIndex: number,
}

instances.COMPONENT = '@react/component'

local contextIds = 0

function instances.newContext(default: any): Context
  contextIds += 1
  return { default = default, id = contextIds }
end

function instances.new(
  root: Root,
  definition: Definition,
  props: { [string]: any },
  parent: Instance?,
  key: string?
): Instance
  return {
    definition = definition,
    key = key,
    props = props,
    parent = parent,
    hooks = {},
    rendered = nil,
    output = {},
    children = {},
    forwards = {},
    contexts = {},
    dirty = true,
    stale = true,
    mounted = true,
    root = root,
  }
end

-- Marks the instance for re-rendering and its ancestors for re-resolving.
function instances.invalidate(instance: Instance): ()
  if not instance.mounted then
    return
  end
  instance.dirty = true
  local current: Instance? = instance
  while current do
    current.stale = true
    current = current.parent
  end
  instance.root.schedule()
end

local function shallowEqual(first: { [string]: any }, second: { [string]: any }): boolean
  for name, value in first do
    local other = second[name]
    if value ~= other and not (type(value) == 'function' and type(other) == 'function') then
      return false
    end
  end
  for name in second do
    if first[name] == nil then
      return false
    end
  end
  return true
end

local function highest(list: { [any]: any }): number
  local count = 0
  for index in list do
    if type(index) == 'number' and index > count then
      count = index
    end
  end
  return count
end

local resolveInto: (Instance, any, string, { uiHost.Element }, { [string]: boolean }) -> ()

-- Unmounts an instance and its descendants, running effect cleanups children first.
function instances.unmount(instance: Instance): ()
  if not instance.mounted then
    return
  end
  for _, child in instance.children do
    instances.unmount(child)
  end
  instance.mounted = false
  for _, hook in instance.hooks do
    local cleanup = hook.cleanup
    if type(cleanup) == 'function' then
      hook.cleanup = nil
      instance.root.report(`ui: {instance.definition.name} effect cleanup`, cleanup)
    end
  end
end

-- The props a render sees. A function prop is a stable function that calls the latest prop, so a child that is not
-- rendered again, because its props compared equal, still calls its parent's newest callback.
local function view(instance: Instance): { [string]: any }
  local given: { [string]: any } = {}
  for name, value in instance.props do
    if type(value) == 'function' then
      local forward = instance.forwards[name]
      if not forward then
        forward = function(...: any): ...any
          local latest = instance.props[name]
          if type(latest) == 'function' then
            return (latest :: (...any) -> ...any)(...)
          end
          return nil
        end
        instance.forwards[name] = forward
      end
      given[name] = forward
    else
      given[name] = value
    end
  end
  return given
end

local function render(instance: Instance): ()
  local root = instance.root
  local previousRendering, previousIndex = root.rendering, root.hookIndex
  root.rendering, root.hookIndex = instance, 0
  local hookCount = #instance.hooks
  -- Hook tables are restored in place on failure: setters and queued effects hold the tables themselves.
  local saved: { Hook } = {}
  for index, hook in instance.hooks do
    saved[index] = table.clone(hook)
  end
  local effectCount = #root.effects
  local ok, result = pcall(instance.definition.render, view(instance))
  local used = root.hookIndex
  root.rendering, root.hookIndex = previousRendering, previousIndex
  if ok and instance.rendered ~= nil and used ~= hookCount then
    ok, result = false, `{instance.definition.name} called {used} hooks, but {hookCount} on its previous render`
  end
  if not ok then
    -- A failed render keeps the previous successful render's hook values and output, and its effects do not run.
    for index = #instance.hooks, 1, -1 do
      local hook = instance.hooks[index]
      local before = saved[index]
      if before then
        table.clear(hook)
        for name, value in before do
          hook[name] = value
        end
      else
        instance.hooks[index] = nil
      end
    end
    for index = #root.effects, effectCount + 1, -1 do
      root.effects[index] = nil
    end
    root.report(`ui: {instance.definition.name} render`, function(): ()
      error(result, 0)
    end)
    return
  end
  instance.rendered = if result == nil then false else result
end

-- Resolves the instance to host elements, rendering it first when it is dirty.
function instances.resolve(instance: Instance): { uiHost.Element }
  if instance.dirty then
    instance.dirty = false
    render(instance)
  elseif not instance.stale then
    return instance.output
  end
  instance.stale = false
  local output: { uiHost.Element } = {}
  local seen: { [string]: boolean } = {}
  if instance.rendered then
    resolveInto(instance, instance.rendered, '', output, seen)
  end
  for path, child in instance.children do
    if not seen[path] then
      instances.unmount(child)
      instance.children[path] = nil
    end
  end
  instance.output = output
  return output
end

-- Rebuilds a host element whose children contain components, keeping the element itself when nothing changed.
local function resolveElement(
  owner: Instance,
  element: uiHost.Element,
  path: string,
  seen: { [string]: boolean }
): uiHost.Element
  local children: { uiHost.Element }, slots: { string } = {}, {}
  local changed = false
  for index, child in element.children do
    local slot = if element.slots then element.slots[index] else child.key or '#' .. index
    local before = #children
    resolveInto(owner, child, path .. '/' .. slot, children, seen)
    -- A component that resolves to one element takes the component's slot, so the host keeps its node; several
    -- elements extend the slot with their own keys or positions.
    local produced = #children - before
    for offset = 1, produced do
      local made = children[before + offset]
      slots[before + offset] = if produced == 1 then slot else slot .. ':' .. (made.key or '#' .. offset)
    end
    if produced ~= 1 or children[before + 1] ~= child then
      changed = true
    end
  end
  if not changed then
    return element
  end
  return table.freeze {
    kind = element.kind,
    key = element.key,
    ref = element.ref,
    props = element.props,
    children = table.freeze(children),
    slots = table.freeze(slots),
  }
end

local function resolveNode(
  owner: Instance,
  node: any,
  path: string,
  into: { uiHost.Element },
  seen: { [string]: boolean }
): ()
  if node == nil or node == false then
    return
  end
  assert(type(node) == 'table', `ui: {owner.definition.name} rendered a {type(node)}, not an element`)
  if node.kind == instances.COMPONENT then
    local component = node :: ComponentElement
    local childPath = path .. '@' .. component.component.name
    seen[childPath] = true
    local existing = owner.children[childPath]
    if existing and existing.definition ~= component.component then
      instances.unmount(existing)
      existing = nil
    end
    local child: Instance
    if existing then
      child = existing
      if not shallowEqual(child.props, component.props) then
        child.dirty = true
      end
      child.props = component.props
    else
      child = instances.new(owner.root, component.component, component.props, owner, component.key)
      owner.children[childPath] = child
    end
    for _, element in instances.resolve(child) do
      into[#into + 1] = element
    end
    return
  end
  if node.kind ~= nil then
    into[#into + 1] = resolveElement(owner, node :: uiHost.Element, path, seen)
    return
  end
  for index = 1, highest(node) do
    local item = node[index]
    local key = if type(item) == 'table' then item.key else nil
    resolveNode(owner, item, path .. ':' .. (key or '#' .. index), into, seen)
  end
end

resolveInto = resolveNode

-- The hook at the current position of the rendering component, created by `create` on first use.
function instances.hook(kind: string, create: () -> Hook): (Hook, Instance)
  local root = instances.current
  local instance = assert(root and root.rendering, `ui: {kind} is called outside a component's render`)
  root.hookIndex += 1
  local index = root.hookIndex
  local hook = instance.hooks[index]
  if hook == nil then
    if instance.rendered ~= nil then
      error(`ui: {instance.definition.name} called more hooks than on its previous render`, 0)
    end
    hook = create()
    hook.kind = kind
    instance.hooks[index] = hook
  elseif hook.kind ~= kind then
    error(`ui: {instance.definition.name} called {kind} where it called {hook.kind} on its previous render`, 0)
  end
  return hook, instance
end

-- The root whose render pass is running; hooks find their instance through it.
instances.current = nil :: Root?

return instances
