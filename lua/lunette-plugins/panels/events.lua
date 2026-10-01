-- Owned dropped listeners and internal resource cleanup for panels.

local plugin = require '@lunette-plugin'
local panels = require '@lunette-contracts/panels'
local vocabulary = require '@lunette-contracts/vocabulary'

local events = {}
local resourceCleanups: { [panels.Panel]: () -> () } = {}

function events.attachCleanup(panel: panels.Panel, cleanup: () -> ())
  if panel.dead or resourceCleanups[panel] then
    error 'panels: cleanup belongs to one live panel'
  end
  resourceCleanups[panel] = cleanup
end

function events.detachCleanup(panel: panels.Panel)
  resourceCleanups[panel] = nil
end

function events.releaseCleanup(panel: panels.Panel)
  local cleanup = resourceCleanups[panel]
  resourceCleanups[panel] = nil
  if cleanup then
    cleanup()
  end
end

type Listener = {
  owner: panels.Owner?,
  panel: panels.Panel?,
  callback: panels.DroppedCallback?,
  active: boolean,
}

export type Registry = {
  listeners: { Listener },
}

export type Context = plugin.Context

local function release(listener: Listener)
  listener.active = false
  listener.callback = nil
  listener.owner = nil
  listener.panel = nil
end

function events.new(): Registry
  return { listeners = {} }
end

function events.onDropped(
  registry: Registry,
  context: Context,
  owner: panels.Owner,
  panel: panels.Panel?,
  callback: panels.DroppedCallback
): plugin.Effect
  return context:acquire(owner, function(): () -> ()
    local listener: Listener = { owner = owner, panel = panel, callback = callback, active = true }
    registry.listeners[#registry.listeners + 1] = listener
    return function()
      release(listener)
      local index = table.find(registry.listeners, listener)
      if index then
        table.remove(registry.listeners, index)
      end
    end
  end)
end

function events.emitDropped(
  registry: Registry,
  context: Context,
  owner: panels.Owner,
  panel: panels.Panel,
  pointer: vocabulary.Pointer
): ()
  context:checkOwner(owner)
  local listeners = table.clone(registry.listeners)
  for _, listener in ipairs(listeners) do
    local listenerOwner = listener.owner
    if listener.active and listenerOwner and (not listener.panel or listener.panel == panel) then
      -- Unloading invalidates the owner before its listener inverse runs.
      local callback = listener.callback
      if context:owns(listenerOwner) and listener.active and callback then
        callback(panel, pointer)
      end
    end
  end
end

function events.clear(registry: Registry)
  for _, listener in ipairs(registry.listeners) do
    release(listener)
  end
  table.clear(registry.listeners)
end

return events
