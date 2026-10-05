-- Publishes owner-scoped notifications when a surface grab ends.
local plugin = require '@lunette-plugin'
local contract = require '@lunette-contracts/drops'
local listeners = require '@lunette-plugins/listeners'

local LISTENER_KEYS: { [string]: boolean } = { run = true }
local DROP_KEYS: { [string]: boolean } = { surface = true, pointer = true }

local function create(context: plugin.Context): contract.Service
  local heard = listeners.new<<(contract.Drop) -> ()>>(context)
  return {
    onDropped = function(_self: contract.Service, owner: contract.Owner, listener: contract.Listener): plugin.Effect
      plugin.rejectUnknownFields('drops onDropped', listener, LISTENER_KEYS, 'run', 2)
      local run = listener.run
      if type(run) ~= 'function' then
        error('drops onDropped: run is a function, not a ' .. type(run), 2)
      end
      return heard:add(owner, run)
    end,
    -- Disposed listeners are skipped even when they appear in the current delivery snapshot.
    emit = function(_self: contract.Service, owner: contract.Owner, drop: contract.Drop): ()
      plugin.rejectUnknownFields('drops emit', drop, DROP_KEYS, 'surface and pointer', 2)
      if type(drop.surface) ~= 'table' then
        error('drops emit: surface is a surface, not a ' .. type(drop.surface), 2)
      end
      if type(drop.pointer) ~= 'table' then
        error('drops emit: pointer is a pointer, not a ' .. type(drop.pointer), 2)
      end
      context:checkOwner(owner)
      local delivered: contract.Drop = table.freeze { surface = drop.surface, pointer = drop.pointer }
      heard:each('drops: listener', function(run: (contract.Drop) -> ()): ()
        run(delivered)
      end)
    end,
  }
end

local config = require '@lunette-plugins/drops/config'

export type Config = config.Config
export type Settings = config.Settings
export type Service = contract.Service

return plugin.provider<<Config, Settings, Service>> {
  name = 'drops',
  schema = config,
  capability = contract.capability,
  build = create,
}
