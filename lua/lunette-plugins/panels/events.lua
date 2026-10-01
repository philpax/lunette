-- Owned dropped, added, and removed listeners for one panels activation.
--
-- Each registry belongs to one provider activation. A listener is an effect of
-- its owner, and it is delivered to only while the provider still owns that
-- owner: unloading invalidates the owner before its listener inverse runs.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local panels = require '@lunette-contracts/panels'
local vocabulary = require '@lunette-contracts/vocabulary'

local events = {}

type Listener<T> = {
  owner: panels.Owner?,
  panel: panels.Panel?,
  callback: T?,
  active: boolean,
}

export type Registry = {
  dropped: { Listener<panels.DroppedCallback> },
  added: { Listener<panels.PanelCallback> },
  removed: { Listener<panels.PanelCallback> },
}

export type Context = plugin.Context

function events.new(): Registry
  return { dropped = {}, added = {}, removed = {} }
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

-- The listeners a panel event reaches, chosen before any is called, so a
-- listener added by another listener does not hear this delivery.
local function reached<T>(list: { Listener<T> }, panel: panels.Panel): { Listener<T> }
  local result: { Listener<T> } = {}
  for _, listener in ipairs(list) do
    if listener.active and (not listener.panel or listener.panel == panel) then
      result[#result + 1] = listener
    end
  end
  return result
end

-- A listener's callback while it is still registered and its owner is still
-- live: an earlier listener may have disposed it, or unloading may have
-- invalidated its owner before its inverse ran.
local function live<T>(listener: Listener<T>, context: Context): T?
  local owner = listener.owner
  if listener.active and owner and context:owns(owner) then
    return listener.callback
  end
  return nil
end

-- Calls one listener, reporting its error rather than raising it into the
-- operation that added or removed the panel, which belongs to another plugin.
local function deliver(kind: string, callback: panels.PanelCallback, panel: panels.Panel): ()
  local message: string? = nil
  local traceback = ''
  xpcall(function()
    callback(panel)
  end, function(raised: unknown)
    message = tostring(raised)
    traceback = debug.traceback('', 2)
  end)
  if message then
    lunette.reportError('panels: ' .. kind .. ' listener', message, traceback)
  end
end

function events.onDropped(
  registry: Registry,
  context: Context,
  owner: panels.Owner,
  panel: panels.Panel?,
  callback: panels.DroppedCallback
): plugin.Effect
  return listen(registry.dropped, context, owner, panel, callback)
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

function events.emitDropped(
  registry: Registry,
  context: Context,
  owner: panels.Owner,
  panel: panels.Panel,
  pointer: vocabulary.Pointer
): ()
  context:checkOwner(owner)
  for _, listener in ipairs(reached(registry.dropped, panel)) do
    local callback = live(listener, context)
    if callback then
      callback(panel, pointer)
    end
  end
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
  for _, list in ipairs { registry.dropped, registry.added, registry.removed } do
    for _, listener in ipairs(list) do
      release(listener)
    end
    table.clear(list)
  end
end

return events
