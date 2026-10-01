-- The drops provider: a broker between what ends grabs and what reacts.
--
-- Each activation keeps its own listeners. A listener belongs to the owner
-- that registered it and ends with that owner. The provider takes no options.

local plugin = require '@lunette-plugin'
local contract = require '@lunette-contracts/drops'
local protected = require '@lunette-plugins/protected'

type Listener = {
  owner: contract.Owner,
  run: (contract.Drop) -> (),
  active: boolean,
}

local LISTENER_KEYS: { [string]: boolean } = { run = true }
local DROP_KEYS: { [string]: boolean } = { surface = true, pointer = true }

local function checkFields(operation: string, value: unknown, allowed: { [string]: boolean }, fields: string): ()
  if type(value) ~= 'table' then
    error(string.format('drops %s: the argument is a table of fields, not a %s', operation, type(value)), 3)
  end
  for key, _ in value :: { [unknown]: unknown } do
    if type(key) ~= 'string' or not allowed[key] then
      error(string.format('drops %s: unknown field %s; the fields are %s', operation, tostring(key), fields), 3)
    end
  end
end

local function create(context: plugin.Context): contract.Service
  local listeners: { Listener } = {}
  return {
    onDropped = function(_self: contract.Service, owner: contract.Owner, listener: contract.Listener): plugin.Effect
      checkFields('onDropped', listener, LISTENER_KEYS, 'run')
      local run = listener.run
      if type(run) ~= 'function' then
        error('drops onDropped: run is a function, not a ' .. type(run), 2)
      end
      local entry: Listener = { owner = owner, run = run, active = true }
      return context:acquire(owner, function(): () -> ()
        listeners[#listeners + 1] = entry
        return function(): ()
          entry.active = false
          local index = table.find(listeners, entry)
          if index then
            table.remove(listeners, index)
          end
        end
      end)
    end,
    -- The listeners are chosen before any is called, so a listener added by
    -- another does not hear this drop, and one disposed by another is skipped.
    emit = function(_self: contract.Service, owner: contract.Owner, drop: contract.Drop): ()
      checkFields('emit', drop, DROP_KEYS, 'surface and pointer')
      if type(drop.surface) ~= 'table' then
        error('drops emit: surface is a surface, not a ' .. type(drop.surface), 2)
      end
      if type(drop.pointer) ~= 'table' then
        error('drops emit: pointer is a pointer, not a ' .. type(drop.pointer), 2)
      end
      context:checkOwner(owner)
      local delivered: contract.Drop = table.freeze { surface = drop.surface, pointer = drop.pointer }
      for _, entry in ipairs(table.clone(listeners)) do
        if entry.active and context:owns(entry.owner) then
          protected.call('drops: listener', function(): ()
            entry.run(delivered)
          end)
        end
      end
    end,
  }
end

export type Config = {}
export type Settings = {}
export type Service = contract.Service

return plugin.provider<<Config, Settings, Service>> {
  name = 'drops',
  capability = contract.capability,
  defaults = {},
  build = function(context: plugin.Context, _settings: Settings): Service
    return create(context)
  end,
}
