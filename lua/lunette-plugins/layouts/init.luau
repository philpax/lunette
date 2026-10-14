-- Named layout registrations and change listeners belong to their registering owners.

local plugin = require '@lunette-plugin'
local contract = require '@lunette-contracts/layouts'
local listeners = require '@lunette-plugins/registration/listeners'
local registry = require '@lunette-plugins/registration/registry'
local inspection = require '@lunette-contracts/inspection'

type Registration = {
  apply: ({ contract.Panel }) -> (),
  continuous: boolean,
}

type Raw = { [unknown]: unknown }

local LAYOUT_KEYS: { string } = { 'name', 'apply', 'continuous' }
local APPLICATION_KEYS: { string } = { 'name', 'panels' }

local function checkName(operation: string, name: unknown): string
  if type(name) ~= 'string' or name == '' then
    error('layouts ' .. operation .. ': name is a non-empty string, not ' .. tostring(name), 3)
  end
  return name :: string
end

local function create(context: plugin.Context): contract.Service
  local heard = listeners.new<<() -> ()>>(context)
  local named = registry.new<<Registration>>(context, 'layouts register', function(): ()
    heard:each('layouts: a change listener', function(run: () -> ()): ()
      run()
    end)
  end)

  local function registeredNames(): { string }
    local names: { string } = {}
    for _, entry in named:list() do
      names[#names + 1] = entry.name
    end
    table.sort(names)
    return names
  end

  return {
    inspect = function(_self: contract.Service): inspection.Snapshot
      local result = heard:inspect 'layouts.onChanged'
      for _, entry in named:inspect('layout', 'layouts.register') do
        result[#result + 1] = entry
      end
      return inspection.snapshot(result, nil, { 'layout applications are transient callbacks' })
    end,
    register = function(_self: contract.Service, owner: contract.Owner, spec: contract.Layout): plugin.Effect
      plugin.rejectUnknownFields('layouts register', spec, LAYOUT_KEYS, 2)
      local raw = (spec :: unknown) :: Raw
      local name = checkName('register', raw.name)
      if type(raw.apply) ~= 'function' then
        error('layouts register: apply is a function, not a ' .. type(raw.apply), 2)
      end
      if raw.continuous ~= nil and type(raw.continuous) ~= 'boolean' then
        error('layouts register: continuous is a boolean, not a ' .. type(raw.continuous), 2)
      end
      local continuous = spec.continuous == true
      return named:add(owner, name, { apply = spec.apply, continuous = continuous }, { continuous = continuous })
    end,
    apply = function(_self: contract.Service, application: contract.Application): ()
      plugin.rejectUnknownFields('layouts apply', application, APPLICATION_KEYS, 2)
      local raw = (application :: unknown) :: Raw
      local name = checkName('apply', raw.name)
      if type(raw.panels) ~= 'table' then
        error('layouts apply: panels is a list of panels, not a ' .. type(raw.panels), 2)
      end
      local registration = named:get(name)
      if not registration then
        local names = registeredNames()
        local known = if #names == 0 then 'none is registered' else 'the layouts are ' .. table.concat(names, ', ')
        error('layouts apply: no layout is registered as ' .. name .. '; ' .. known, 2)
      end
      local given: { read [number]: contract.Panel } = application.panels
      local panels: { contract.Panel } = {}
      for index = 1, #given do
        local panel = given[index]
        if not panel.dead then
          panels[#panels + 1] = panel
        end
      end
      registration.apply(panels)
    end,
    list = function(_self: contract.Service): { read [number]: contract.Entry }
      local entries: { contract.Entry } = {}
      for _, name in registeredNames() do
        local registration = named:get(name) :: Registration
        entries[#entries + 1] = table.freeze { name = name, continuous = registration.continuous }
      end
      return entries
    end,
    get = function(_self: contract.Service, name: string): contract.Entry?
      local registration = named:get(name)
      if not registration then
        return nil
      end
      return table.freeze { name = name, continuous = registration.continuous }
    end,
    onChanged = function(_self: contract.Service, owner: contract.Owner, spec: contract.ChangedListener): plugin.Effect
      listeners.check('layouts onChanged', spec)
      return heard:add(owner, spec.run)
    end,
  }
end

export type Config = {}
export type Settings = {}
export type Service = contract.Service

return plugin.provider<<Config, Settings, Service>> {
  name = 'layouts',
  capability = contract.capability,
  build = create,
}
