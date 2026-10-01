-- The layouts provider: a broker for named layouts.
--
-- Each activation keeps its own registrations, keyed by name, and its own
-- change listeners. A registration and a listener belong to the owner that
-- made them and end with that owner. The provider takes no options.

local plugin = require '@lunette-plugin'
local contract = require '@lunette-contracts/layouts'
local protected = require '@lunette-plugins/protected'

type Registration = {
  owner: contract.Owner,
  name: string,
  apply: ({ contract.Panel }, unknown?) -> (),
  continuous: boolean,
}

type Listener = {
  owner: contract.Owner,
  run: () -> (),
  active: boolean,
}

type Raw = { [unknown]: unknown }

local LAYOUT_KEYS: { [string]: boolean } = { name = true, apply = true, continuous = true }
local APPLICATION_KEYS: { [string]: boolean } = { name = true, panels = true, options = true }

local function checkFields(operation: string, spec: unknown, allowed: { [string]: boolean }, fields: string): Raw
  if type(spec) ~= 'table' then
    error('layouts ' .. operation .. ': the argument is a table of fields, not a ' .. type(spec), 3)
  end
  for key, _ in spec :: Raw do
    if type(key) ~= 'string' or not allowed[key] then
      error('layouts ' .. operation .. ': unknown field ' .. tostring(key) .. '; the fields are ' .. fields, 3)
    end
  end
  return spec :: Raw
end

local function checkName(operation: string, name: unknown): string
  if type(name) ~= 'string' or name == '' then
    error('layouts ' .. operation .. ': name is a non-empty string, not ' .. tostring(name), 3)
  end
  return name :: string
end

local function create(context: plugin.Context): contract.Service
  local named: { [string]: Registration } = {}
  local listeners: { Listener } = {}

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
    for _, listener in ipairs(table.clone(listeners)) do
      if listener.active and context:owns(listener.owner) then
        protected.call('layouts: a change listener', listener.run)
      end
    end
  end

  return {
    register = function(_self: contract.Service, owner: contract.Owner, spec: contract.Layout): plugin.Effect
      local raw = checkFields('register', spec, LAYOUT_KEYS, 'name, apply, and continuous')
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
      local raw = checkFields('apply', application, APPLICATION_KEYS, 'name, panels, and options')
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
      local given: { contract.Panel } = application.panels
      local panels: { contract.Panel } = {}
      for _, panel in ipairs(given) do
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
      local raw = checkFields('onChanged', spec, { run = true }, 'run')
      if type(raw.run) ~= 'function' then
        error('layouts onChanged: run is a function, not a ' .. type(raw.run), 2)
      end
      local listener: Listener = { owner = owner, run = spec.run, active = true }
      return context:acquire(owner, function(): () -> ()
        listeners[#listeners + 1] = listener
        return function(): ()
          listener.active = false
          local index = table.find(listeners, listener)
          if index then
            table.remove(listeners, index)
          end
        end
      end)
    end,
  }
end

export type Config = {}
export type Settings = {}
export type Service = contract.Service

return plugin.provider<<Config, Settings, Service>> {
  name = 'layouts',
  capability = contract.capability,
  defaults = {},
  build = function(context: plugin.Context, _settings: Settings): Service
    return create(context)
  end,
}
