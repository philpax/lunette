-- Surface offers are named, ordered, and scoped to their owners.

local plugin = require '@lunette-plugin'
local contract = require '@lunette-contracts/surfaces'
local protected = require '@lunette-plugins/protected'
local registry = require '@lunette-plugins/registry'
local inspection = require '@lunette-contracts/inspection'

local OFFER_KEYS: { string } = { 'name', 'list' }

local function create(context: plugin.Context): contract.Service
  local offers = registry.new<<() -> { contract.Surface }>>(context, 'surfaces offer')

  return {
    inspect = function(_self: contract.Service): inspection.Snapshot
      return inspection.snapshot(offers:inspect('offer', 'surfaces.offer'), nil, { 'offer results require callbacks' })
    end,
    offer = function(_self: contract.Service, owner: contract.Owner, spec: contract.Offer): plugin.Effect
      plugin.rejectUnknownFields('surfaces offer', spec, OFFER_KEYS, 2)
      local name, list = spec.name, spec.list
      if type(name) ~= 'string' or name == '' then
        error('surfaces offer: name is a non-empty string, not ' .. tostring(name), 2)
      end
      if type(list) ~= 'function' then
        error('surfaces offer: list is a function, not a ' .. type(list), 2)
      end
      return offers:add(owner, name, list)
    end,
    all = function(_self: contract.Service): { contract.Surface }
      local result: { contract.Surface } = {}
      for _, entry in offers:list() do
        -- An offer an earlier one ended during this query contributes nothing.
        if offers:get(entry.name) == entry.value then
          local listed: { contract.Surface }? = nil
          local ok = protected.call('surfaces: ' .. entry.name, function(): ()
            local answered: unknown = entry.value()
            if type(answered) ~= 'table' then
              error('the offer answered a ' .. type(answered) .. ', not a list of surfaces', 0)
            end
            listed = answered :: { contract.Surface }
          end)
          if ok and listed then
            for _, candidate in ipairs(listed) do
              result[#result + 1] = candidate
            end
          end
        end
      end
      return result
    end,
  }
end

export type Config = {}
export type Settings = {}
export type Service = contract.Service

return plugin.provider<<Config, Settings, Service>> {
  name = 'surfaces',
  capability = contract.capability,
  build = create,
}
