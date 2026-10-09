-- Publishes owner-scoped notifications when a surface grab ends.
local plugin = require '@lunette-plugin'
local contract = require '@lunette-contracts/drops'
local listeners = require '@lunette-plugins/listeners'
local inspection = require '@lunette-contracts/inspection'

local LISTENER_KEYS: { string } = { 'run' }

local function create(context: plugin.Context): contract.Service
  local heard = listeners.new<<(contract.Drop) -> ()>>(context)
  return {
    inspect = function(_self: contract.Service): inspection.Snapshot
      return inspection.snapshot(heard:inspect 'drops.onDropped', nil, { 'drops are transient notifications' })
    end,
    onDropped = function(_self: contract.Service, owner: contract.Owner, listener: contract.Listener): plugin.Effect
      plugin.rejectUnknownFields('drops onDropped', listener, LISTENER_KEYS, 2)
      local run = listener.run
      if type(run) ~= 'function' then
        error('drops onDropped: run is a function, not a ' .. type(run), 2)
      end
      return heard:add(owner, run)
    end,
    -- Disposed listeners are skipped even when they appear in the current delivery snapshot. The interaction
    -- provider is the only emitter, so the drop is not validated.
    emit = function(_self: contract.Service, owner: contract.Owner, drop: contract.Drop): ()
      context:checkOwner(owner)
      local delivered: contract.Drop = table.freeze { surface = drop.surface, pointer = drop.pointer }
      heard:each('drops: listener', function(run: (contract.Drop) -> ()): ()
        run(delivered)
      end)
    end,
  }
end

export type Config = {}
export type Settings = {}
export type Service = contract.Service

return plugin.provider<<Config, Settings, Service>> {
  name = 'drops',
  capability = contract.capability,
  build = create,
}
