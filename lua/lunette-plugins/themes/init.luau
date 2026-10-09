-- Named theme registrations and change listeners belong to their registering owners.

local plugin = require '@lunette-plugin'
local contract = require '@lunette-contracts/themes'
local inspection = require '@lunette-contracts/inspection'
local descriptors = require '@lunette-plugins/theme/descriptors'
local listeners = require '@lunette-plugins/listeners'

type Registration = {
  owner: contract.Owner,
  entry: contract.Entry,
}

type Raw = { [unknown]: unknown }

local REGISTRATION_KEYS: { [string]: boolean } = { name = true, label = true, order = true, theme = true }

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
  local named: { [string]: Registration } = {}
  local heard = listeners.new<<() -> ()>>(context)

  local function live(name: string): Registration?
    local registration = named[name]
    if registration and context:owns(registration.owner) then
      return registration
    end
    return nil
  end

  local function entries(): { contract.Entry }
    local result: { contract.Entry } = {}
    for name in named do
      local registration = live(name)
      if registration then
        result[#result + 1] = registration.entry
      end
    end
    table.sort(result, before)
    return result
  end

  local function changed(): ()
    heard:each('themes: a change listener', function(run: () -> ()): ()
      run()
    end)
  end

  return {
    inspect = function(_self: contract.Service): inspection.Snapshot
      local result = heard:inspect 'themes.onChanged'
      local names: { string } = {}
      for name in named do
        names[#names + 1] = name
      end
      table.sort(names)
      for _, name in names do
        local registration = named[name]
        local entry = registration.entry
        result[#result + 1] = inspection.registration(
          'theme',
          'themes.register',
          registration.owner,
          name,
          context:owns(registration.owner),
          { label = entry.label, order = entry.order, font = descriptors.fontKey(entry.theme.typography.font) }
        )
      end
      return inspection.snapshot(result)
    end,
    register = function(_self: contract.Service, owner: contract.Owner, spec: contract.Registration): plugin.Effect
      plugin.rejectUnknownFields('themes register', spec, REGISTRATION_KEYS, 'name, label, order, and theme', 2)
      local raw = (spec :: unknown) :: Raw
      local name = checkText('name', raw.name)
      local label = checkText('label', raw.label)
      local order = checkOrder(raw.order)
      local complete = descriptors.theme.parse(raw.theme, 'themes register ' .. name)
      if named[name] then
        error('themes register: ' .. name .. ' is already registered', 2)
      end
      local registration: Registration = {
        owner = owner,
        entry = table.freeze { name = name, label = label, order = order, theme = complete },
      }
      local effect = context:acquire(owner, function(): () -> ()
        if named[name] then
          error('themes register: ' .. name .. ' is already registered', 0)
        end
        named[name] = registration
        return function(): ()
          if named[name] == registration then
            named[name] = nil
            changed()
          end
        end
      end)
      changed()
      return effect
    end,
    list = function(_self: contract.Service): { read [number]: contract.Entry }
      return entries()
    end,
    names = function(_self: contract.Service): { string }
      local names: { string } = {}
      for index, entry in entries() do
        names[index] = entry.name
      end
      return names
    end,
    get = function(_self: contract.Service, name: string): contract.Entry?
      local registration = live(name)
      return if registration then registration.entry else nil
    end,
    onChanged = function(_self: contract.Service, owner: contract.Owner, spec: contract.ChangedListener): plugin.Effect
      plugin.rejectUnknownFields('themes onChanged', spec, { run = true }, 'run', 2)
      local raw = (spec :: unknown) :: Raw
      if type(raw.run) ~= 'function' then
        error('themes onChanged: run is a function, not a ' .. type(raw.run), 2)
      end
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
