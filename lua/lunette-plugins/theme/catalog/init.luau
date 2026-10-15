-- Named theme registrations and change listeners belong to their registering owners.

local plugin = require '@lunette-plugin'
local contract = require '@lunette-contracts/themes'
local inspection = require '@lunette-contracts/inspection'
local descriptors = require '@lunette-contracts/schemas/theme'
local listeners = require '@lunette-plugins/registration/listeners'
local registry = require '@lunette-plugins/registration/registry'

type Raw = { [unknown]: unknown }

local REGISTRATION_KEYS: { string } = { 'name', 'label', 'order', 'theme' }

local function checkText(field: string, value: unknown): string
  if type(value) ~= 'string' or value == '' then
    error('themes register: ' .. field .. ' is a non-empty string, not ' .. tostring(value), 3)
  end
  return value :: string
end

local function checkOrder(value: unknown): number
  if value == nil then
    return 0
  end
  if type(value) ~= 'number' or value ~= value or value == math.huge or value == -math.huge then
    error('themes register: order is a finite number, not ' .. tostring(value), 3)
  end
  return value :: number
end

local function before(first: contract.Entry, second: contract.Entry): boolean
  if first.order ~= second.order then
    return first.order < second.order
  end
  return first.name < second.name
end

local function create(context: plugin.Context): contract.Service
  local heard = listeners.new<<() -> ()>>(context)
  local named = registry.new<<contract.Entry>>(context, 'themes register', function(): ()
    heard:each('themes: a change listener', function(run: () -> ()): ()
      run()
    end)
  end)

  return {
    inspect = function(_self: contract.Service): inspection.Snapshot
      local result = heard:inspect 'themes.onChanged'
      for _, entry in named:inspect('theme', 'themes.register') do
        result[#result + 1] = entry
      end
      return inspection.snapshot(result)
    end,
    register = function(_self: contract.Service, owner: contract.Owner, spec: contract.Registration): plugin.Effect
      plugin.rejectUnknownFields('themes register', spec, REGISTRATION_KEYS, 2)
      local raw = (spec :: unknown) :: Raw
      local name = checkText('name', raw.name)
      local label = checkText('label', raw.label)
      local order = checkOrder(raw.order)
      local complete = descriptors.theme.parse(raw.theme, 'themes register ' .. name)
      local entry: contract.Entry = table.freeze { name = name, label = label, order = order, theme = complete }
      return named:add(
        owner,
        name,
        entry,
        { label = label, order = order, font = descriptors.fontKey(complete.typography.font) }
      )
    end,
    list = function(_self: contract.Service): { read [number]: contract.Entry }
      local result: { contract.Entry } = {}
      for _, registration in named:list() do
        result[#result + 1] = registration.value
      end
      table.sort(result, before)
      return result
    end,
    get = function(_self: contract.Service, name: string): contract.Entry?
      return named:get(name)
    end,
    onChanged = function(_self: contract.Service, owner: contract.Owner, spec: contract.ChangedListener): plugin.Effect
      listeners.check('themes onChanged', spec)
      return heard:add(owner, spec.run)
    end,
  }
end

export type Config = {}
export type Settings = {}
export type Service = contract.Service

return plugin.provider<<Config, Settings, Service>> {
  name = 'themes',
  capability = contract.capability,
  build = create,
}
