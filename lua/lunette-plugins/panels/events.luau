-- Panel callbacks use owner-checked registration snapshots.

local plugin = require '@lunette-plugin'
local panels = require '@lunette-contracts/panels'
local listeners = require '@lunette-plugins/listeners'

local events = {}

type RemovedListener = {
  read panel: panels.Panel?,
  read callback: panels.PanelCallback,
}

export type Registry = {
  read added: listeners.Listeners<panels.PanelCallback>,
  read removed: listeners.Listeners<RemovedListener>,
}

function events.new(context: plugin.Context): Registry
  return { added = listeners.new<<panels.PanelCallback>>(context), removed = listeners.new<<RemovedListener>>(context) }
end

function events.onAdded(registry: Registry, owner: panels.Owner, callback: panels.PanelCallback): plugin.Effect
  return registry.added:add(owner, callback)
end

function events.onRemoved(
  registry: Registry,
  owner: panels.Owner,
  panel: panels.Panel?,
  callback: panels.PanelCallback
): plugin.Effect
  return registry.removed:add(owner, { panel = panel, callback = callback })
end

function events.emitAdded(registry: Registry, panel: panels.Panel): ()
  registry.added:each('panels: added listener', function(callback)
    callback(panel)
  end)
end

function events.emitRemoved(registry: Registry, panel: panels.Panel): ()
  registry.removed:each('panels: removed listener', function(listener)
    listener.callback(panel)
  end, function(listener)
    return listener.panel == nil or listener.panel == panel
  end)
end

function events.clear(registry: Registry): ()
  registry.added:clear()
  registry.removed:clear()
end

return events
