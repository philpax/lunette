-- Independent child consumers keep broker inspection outages from disabling the management surface.

local plugin = require '@lunette-plugin'
local inspection = require '@lunette-contracts/inspection'
local details = require './details'
local frame = require '@lunette-contracts/frame'
local surfaces = require '@lunette-contracts/surfaces'
local bindings = require '@lunette-contracts/bindings'
local panels = require '@lunette-contracts/panels'
local focus = require '@lunette-contracts/focus'
local drops = require '@lunette-contracts/drops'
local tags = require '@lunette-contracts/tags'
local rules = require '@lunette-contracts/rules'
local placement = require '@lunette-contracts/placement'
local layouts = require '@lunette-contracts/layouts'
local adoption = require '@lunette-contracts/adoption'
local keyboard = require '@lunette-contracts/keyboard'
local laser = require '@lunette-contracts/laser'
local interaction = require '@lunette-contracts/interaction'
local errors = require '@lunette-contracts/errors'
local pacing = require '@lunette-contracts/pacing'

local brokers = {}

export type Reader = {
  read name: string,
  inspect: (() -> inspection.Snapshot)?,
}

function brokers.watch(context: plugin.Context): { Reader }
  local readers: { Reader } = {}
  local function add<T>(name: string, capability: plugin.Capability<T>, inspect: (T) -> inspection.Snapshot): ()
    local reader: Reader = { name = name, inspect = nil }
    readers[#readers + 1] = reader
    local definition = plugin.define {
      name = 'desktop/manager/inspect/' .. name,
      requires = { service = capability },
      init = function(child: plugin.Context, _config: {}, _publish: plugin.Publisher): ()
        local service = child:require(capability)
        child:effect(function(): () -> ()
          reader.inspect = function(): inspection.Snapshot
            return inspect(service)
          end
          return function(): ()
            reader.inspect = nil
          end
        end)
      end,
    }
    context:child(definition, {})
  end
  add('frame', frame.capability, function(service: frame.Service): inspection.Snapshot
    return service:inspect()
  end)
  add('surfaces', surfaces.capability, function(service: surfaces.Service): inspection.Snapshot
    return service:inspect()
  end)
  add('bindings', bindings.capability, function(service: bindings.Service): inspection.Snapshot
    return service:inspect()
  end)
  add('panels', panels.capability, function(service: panels.Service): inspection.Snapshot
    return service:inspect()
  end)
  add('focus', focus.capability, function(service: focus.Service): inspection.Snapshot
    return service:inspect()
  end)
  add('drops', drops.capability, function(service: drops.Service): inspection.Snapshot
    return service:inspect()
  end)
  add('tags', tags.capability, function(service: tags.Service): inspection.Snapshot
    return service:inspect()
  end)
  add('rules', rules.capability, function(service: rules.Service): inspection.Snapshot
    return service:inspect()
  end)
  add('placement', placement.capability, function(service: placement.Service): inspection.Snapshot
    return service:inspect()
  end)
  add('layouts', layouts.capability, function(service: layouts.Service): inspection.Snapshot
    return service:inspect()
  end)
  add('adoption', adoption.capability, function(service: adoption.Service): inspection.Snapshot
    return service:inspect()
  end)
  add('keyboard', keyboard.capability, function(service: keyboard.Service): inspection.Snapshot
    return service:inspect()
  end)
  add('laser', laser.capability, function(service: laser.Service): inspection.Snapshot
    return service:inspect()
  end)
  add('interaction', interaction.capability, function(service: interaction.Service): inspection.Snapshot
    return service:inspect()
  end)
  add('errors', errors.capability, function(service: errors.Service): inspection.Snapshot
    return service:inspect()
  end)
  add('pacing', pacing.capability, function(service: pacing.Service): inspection.Snapshot
    return service:inspect()
  end)
  return readers
end

function brokers.snapshot(readers: { Reader }): { details.Broker }
  local result: { details.Broker } = {}
  for _, reader in readers do
    local inspect = reader.inspect
    local snapshot: inspection.Snapshot
    if inspect then
      local ok, value = pcall(inspect)
      snapshot = if ok then value else inspection.snapshot({}, {}, { 'Inspection failed: ' .. tostring(value) })
    else
      snapshot = inspection.snapshot({}, {}, { 'The inspection consumer has no active provider.' })
    end
    result[#result + 1] = table.freeze { name = reader.name, snapshot = snapshot }
  end
  return table.freeze(result)
end

return brokers
