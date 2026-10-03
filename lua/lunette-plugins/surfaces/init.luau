-- The surfaces provider: a broker for the surfaces a pointer can pick, with owner-scoped named offers.

local plugin = require '@lunette-plugin'
local contract = require '@lunette-contracts/surfaces'
local protected = require '@lunette-plugins/protected'

type Offer = {
  owner: contract.Owner,
  name: string,
  list: () -> { contract.Surface },
  active: boolean,
}

local OFFER_KEYS: { [string]: boolean } = { name = true, list = true }

local function create(context: plugin.Context): contract.Service
  local offers: { Offer } = {}
  local named: { [string]: Offer } = {}

  return {
    offer = function(_self: contract.Service, owner: contract.Owner, spec: contract.Offer): plugin.Effect
      if type(spec) ~= 'table' then
        error('surfaces offer: an offer is a table of fields, not a ' .. type(spec), 2)
      end
      plugin.rejectUnknownFields('surfaces offer', spec, OFFER_KEYS, 'name and list', 2)
      local name, list = spec.name, spec.list
      if type(name) ~= 'string' or name == '' then
        error('surfaces offer: name is a non-empty string, not ' .. tostring(name), 2)
      end
      if type(list) ~= 'function' then
        error('surfaces offer: list is a function, not a ' .. type(list), 2)
      end
      if named[name] then
        error('surfaces offer: ' .. name .. ' is already offered', 2)
      end
      local entry: Offer = { owner = owner, name = name, list = list, active = true }
      return context:acquire(owner, function(): () -> ()
        if named[name] then
          error('surfaces offer: ' .. name .. ' is already offered', 0)
        end
        offers[#offers + 1] = entry
        named[name] = entry
        return function(): ()
          entry.active = false
          if named[name] == entry then
            named[name] = nil
          end
          local index = table.find(offers, entry)
          if index then
            table.remove(offers, index)
          end
        end
      end)
    end,
    all = function(_self: contract.Service): { contract.Surface }
      local result: { contract.Surface } = {}
      for _, entry in ipairs(table.clone(offers)) do
        if entry.active and context:owns(entry.owner) then
          local listed: { contract.Surface }? = nil
          local ok = protected.call('surfaces: ' .. entry.name, function(): ()
            local answered: unknown = entry.list()
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
  defaults = {},
  build = function(context: plugin.Context, _settings: Settings): Service
    return create(context)
  end,
}
