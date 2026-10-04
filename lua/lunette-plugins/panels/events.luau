-- Panel event delivery requires a live listener owner.

local plugin = require '@lunette-plugin'
local panels = require '@lunette-contracts/panels'
local protected = require '@lunette-plugins/protected'

local events = {}

type Listener<T> = {
  owner: panels.Owner?,
  panel: panels.Panel?,
  callback: T?,
  active: boolean,
}

export type Registry = {
  added: { Listener<panels.PanelCallback> },
  removed: { Listener<panels.PanelCallback> },
}

export type Context = plugin.Context

function events.new(): Registry
  return { added = {}, removed = {} }
end

local function release<T>(listener: Listener<T>)
  listener.active = false
  listener.callback = nil
  listener.owner = nil
  listener.panel = nil
end

local function listen<T>(
  list: { Listener<T> },
  context: Context,
  owner: panels.Owner,
  panel: panels.Panel?,
  callback: T
): plugin.Effect
  return context:acquire(owner, function(): () -> ()
    local listener: Listener<T> = { owner = owner, panel = panel, callback = callback, active = true }
    list[#list + 1] = listener
    return function()
      release(listener)
      local index = table.find(list, listener)
      if index then
        table.remove(list, index)
      end
    end
  end)
end

-- Event delivery uses a snapshot of matching listeners at dispatch start.
local function reached<T>(list: { Listener<T> }, panel: panels.Panel): { Listener<T> }
  local result: { Listener<T> } = {}
  for _, listener in ipairs(list) do
    if listener.active and (not listener.panel or listener.panel == panel) then
      result[#result + 1] = listener
    end
  end
  return result
end

-- A listener can be disposed or its owner invalidated during an earlier callback.
local function live<T>(listener: Listener<T>, context: Context): T?
  local owner = listener.owner
  if listener.active and owner and context:owns(owner) then
    return listener.callback
  end
  return nil
end

-- Listener errors are reported without failing the panel operation.
local function deliver(kind: string, callback: panels.PanelCallback, panel: panels.Panel): ()
  protected.call('panels: ' .. kind .. ' listener', function()
    callback(panel)
  end)
end

function events.onAdded(
  registry: Registry,
  context: Context,
  owner: panels.Owner,
  callback: panels.PanelCallback
): plugin.Effect
  return listen(registry.added, context, owner, nil, callback)
end

function events.onRemoved(
  registry: Registry,
  context: Context,
  owner: panels.Owner,
  panel: panels.Panel?,
  callback: panels.PanelCallback
): plugin.Effect
  return listen(registry.removed, context, owner, panel, callback)
end

function events.emitAdded(registry: Registry, context: Context, panel: panels.Panel): ()
  for _, listener in ipairs(reached(registry.added, panel)) do
    local callback = live(listener, context)
    if callback then
      deliver('added', callback, panel)
    end
  end
end

function events.emitRemoved(registry: Registry, context: Context, panel: panels.Panel): ()
  for _, listener in ipairs(reached(registry.removed, panel)) do
    local callback = live(listener, context)
    if callback then
      deliver('removed', callback, panel)
    end
  end
end

function events.clear(registry: Registry)
  for _, list in ipairs { registry.added, registry.removed } do
    for _, listener in ipairs(list) do
      release(listener)
    end
    table.clear(list)
  end
end

return events
