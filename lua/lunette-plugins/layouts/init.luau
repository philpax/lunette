-- Named layout registrations and change listeners belong to their registering owners.

local plugin = require '@lunette-plugin'
local contract = require '@lunette-contracts/layouts'
local listeners = require '@lunette-plugins/listeners'

type Registration = {
  owner: contract.Owner,
  name: string,
  apply: ({ contract.Panel }, unknown?) -> (),
  continuous: boolean,
}

type Raw = { [unknown]: unknown }

local LAYOUT_KEYS: { [string]: boolean } = { name = true, apply = true, continuous = true }
local APPLICATION_KEYS: { [string]: boolean } = { name = true, panels = true, options = true }

local function checkName(operation: string, name: unknown): string
  if type(name) ~= 'string' or name == '' then
    error('layouts ' .. operation .. ': name is a non-empty string, not ' .. tostring(name), 3)
  end
  return name :: string
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

  local function registeredNames(): { string }
    local names: { string } = {}
    for name, _ in named do
      if live(name) then
        names[#names + 1] = name
      end
    end
    table.sort(names)
    return names
  end

  local function changed(): ()
    heard:each('layouts: a change listener', function(run: () -> ()): ()
      run()
    end)
  end

  return {
    register = function(_self: contract.Service, owner: contract.Owner, spec: contract.Layout): plugin.Effect
      plugin.rejectUnknownFields('layouts register', spec, LAYOUT_KEYS, 'name, apply, and continuous', 2)
      local raw = (spec :: unknown) :: Raw
      local name = checkName('register', raw.name)
      if type(raw.apply) ~= 'function' then
        error('layouts register: apply is a function, not a ' .. type(raw.apply), 2)
      end
      if raw.continuous ~= nil and type(raw.continuous) ~= 'boolean' then
        error('layouts register: continuous is a boolean, not a ' .. type(raw.continuous), 2)
      end
      if named[name] then
        error('layouts register: ' .. name .. ' is already registered', 2)
      end
      local registration: Registration = {
        owner = owner,
        name = name,
        apply = spec.apply,
        continuous = spec.continuous == true,
      }
      local effect = context:acquire(owner, function(): () -> ()
        if named[name] then
          error('layouts register: ' .. name .. ' is already registered', 0)
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
    apply = function(_self: contract.Service, application: contract.Application): ()
      plugin.rejectUnknownFields('layouts apply', application, APPLICATION_KEYS, 'name, panels, and options', 2)
      local raw = (application :: unknown) :: Raw
      local name = checkName('apply', raw.name)
      if type(raw.panels) ~= 'table' then
        error('layouts apply: panels is a list of panels, not a ' .. type(raw.panels), 2)
      end
      local registration = live(name)
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
      registration.apply(panels, application.options)
    end,
    names = function(_self: contract.Service): { string }
      return registeredNames()
    end,
    get = function(_self: contract.Service, name: string): contract.Entry?
      local registration = live(name)
      if not registration then
        return nil
      end
      return table.freeze { name = registration.name, continuous = registration.continuous }
    end,
    onChanged = function(_self: contract.Service, owner: contract.Owner, spec: contract.ChangedListener): plugin.Effect
      plugin.rejectUnknownFields('layouts onChanged', spec, { run = true }, 'run', 2)
      local raw = (spec :: unknown) :: Raw
      if type(raw.run) ~= 'function' then
        error('layouts onChanged: run is a function, not a ' .. type(raw.run), 2)
      end
      return heard:add(owner, spec.run)
    end,
  }
end

local config = require '@lunette-plugins/layouts/config'

export type Config = config.Config
export type Settings = config.Settings
export type Service = contract.Service

return plugin.provider<<Config, Settings, Service>> {
  name = 'layouts',
  schema = config,
  capability = contract.capability,
  build = create,
}
