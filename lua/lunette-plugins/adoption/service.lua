-- Scoped native-window adoption over the panels and rules providers.
--
-- Installation is deliberately separate from startup. Installation contributes
-- only the native pose source; startup owns the event subscription and every
-- panel it creates. Native windows remain caller-owned and are never closed.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local adoption = require '@lunette-contracts/adoption'
local panelsContract = require '@lunette-contracts/panels'
local interactionContract = require '@lunette-contracts/interaction'
local rulesContract = require '@lunette-contracts/rules'

export type Service = adoption.Service
export type Owner = adoption.Owner
export type Options = adoption.Options
export type Properties = adoption.Properties

local SOURCE = 'lunette.adoption'
local PRECEDENCE = 300

type Required = {
  read panels: panelsContract.Capability,
  read interaction: interactionContract.Capability,
  read rules: rulesContract.Capability,
}

type State = {
  active: boolean,
  context: plugin.Context,
  service: Service,
}

type MutableService = {
  SOURCE: string,
  PRECEDENCE: number,
  properties: (Service, lunette.Window) -> rulesContract.Resolved?,
  source: (Service) -> (lunette.Window) -> adoption.Properties?,
  install: (Service, Owner, number?) -> plugin.Effect,
  windows: (Service) -> { lunette.Window },
  start: (Service, Owner, Options?) -> plugin.Effect,
}

local states: { [Service]: State } = {}

local function stateFor(service: Service): State
  local state = states[service]
  if not state or not state.active or not state.context:active() then
    error 'adoption: service is no longer active'
  end
  return state
end

local function checkWindow(window: lunette.Window)
  local kind = type(window)
  if kind ~= 'table' and kind ~= 'userdata' then
    error('adoption: a window carries the properties, and a ' .. kind .. ' does not', 3)
  end
end

local function properties(state: State, window: lunette.Window): rulesContract.Resolved?
  checkWindow(window)
  local interaction: interactionContract.Service = state.context:require(interactionContract.capability)
  local key = interaction.POSE_PROPERTY
  local kept = window:getProperty(key)
  if type(kept) ~= 'string' then
    return nil
  end
  return { pose = kept }
end

local function windows(state: State): { lunette.Window }
  local result: { lunette.Window } = {}
  local panels: panelsContract.Service = state.context:require(panelsContract.capability)
  for _, window in ipairs(lunette.windows()) do
    if not window.dead and not panels:forSource(window) then
      result[#result + 1] = window
    end
  end
  return result
end

local function source(state: State): (lunette.Window) -> Properties?
  return function(window: lunette.Window): Properties?
    if not state.active or not state.context:active() then
      return nil
    end
    return properties(state, window)
  end
end

local function init(context: plugin.Context): Service
  local implementation: MutableService = {
    SOURCE = SOURCE,
    PRECEDENCE = PRECEDENCE,
    properties = function(_self: Service, window: lunette.Window): rulesContract.Resolved?
      error 'adoption: service is not initialized'
    end,
    source = function(_self: Service): (lunette.Window) -> Properties?
      error 'adoption: service is not initialized'
    end,
    install = function(_self: Service, _owner: Owner, _precedence: number?): plugin.Effect
      error 'adoption: service is not initialized'
    end,
    windows = function(_self: Service): { lunette.Window }
      error 'adoption: service is not initialized'
    end,
    start = function(_self: Service, _owner: Owner, _options: Options?): plugin.Effect
      error 'adoption: service is not initialized'
    end,
  }
  local service: Service = implementation
  local state: State = { active = true, context = context, service = service }
  states[service] = state

  context:effect(function(): () -> ()
    return function()
      state.active = false
      states[service] = nil
    end
  end)

  function implementation.properties(_self: Service, window: lunette.Window): rulesContract.Resolved?
    return properties(stateFor(service), window)
  end

  function implementation.source(_self: Service): (lunette.Window) -> Properties?
    return source(stateFor(service))
  end

  function implementation.install(self: Service, owner: Owner, precedence: number?): plugin.Effect
    local current = stateFor(service)
    current.context:checkOwner(owner)
    local rules: rulesContract.Service = current.context:require(rulesContract.capability)
    local chosen = precedence or PRECEDENCE
    if type(chosen) ~= 'number' or chosen ~= chosen then
      error('adoption: precedence is an orderable number', 2)
    end
    local adoptedSource = self:source()
    local function resolve(window: lunette.Window): rulesContract.Properties?
      local properties = adoptedSource(window)
      if not properties then
        return nil
      end
      return { pose = properties.pose }
    end
    return rules:addSource(owner, SOURCE, chosen, resolve)
  end

  function implementation.windows(_self: Service): { lunette.Window }
    return windows(stateFor(service))
  end

  function implementation.start(self: Service, owner: Owner, options: Options?): plugin.Effect
    local current = stateFor(service)
    current.context:checkOwner(owner)
    local panels: panelsContract.Service = current.context:require(panelsContract.capability)
    local rules: rulesContract.Service = current.context:require(rulesContract.capability)
    local settings: Options = options or {}
    local adopted: { plugin.Effect } = {}
    local adoptedIds: { [number]: boolean } = {}
    local subscription: (() -> ())?
    local active = true

    local function live(): boolean
      if not active or not current.active or not current.context:active() then
        return false
      end
      -- Copied callbacks must still belong to this provider's caller activation.
      local ok = pcall(function()
        current.context:checkOwner(owner)
      end)
      return ok
    end

    local function place(window: lunette.Window)
      if not live() or window.dead or adoptedIds[window.id] or panels:forSource(window) then
        return
      end
      local entered = false
      local panel: panelsContract.WindowPanel?
      local resolved: rulesContract.Resolved?
      local placement: plugin.Effect?
      local ok, failure = pcall(function()
        placement = owner:effect(function(): () -> ()
          entered = true
          current.context:checkOwner(owner)
          adoptedIds[window.id] = true
          local created, properties = rules:place(current.context, window, settings.defaults)
          panel, resolved = created, properties
          return function()
            created:destroy()
          end
        end)
      end)
      if not ok then
        if entered then
          error(failure)
        end
        return
      end
      local acquired = assert(placement)
      if not live() then
        acquired:dispose()
        return
      end
      adopted[#adopted + 1] = acquired
      if settings.onPlaced then
        settings.onPlaced(assert(panel), assert(resolved))
      end
    end

    local effect = owner:effect(function(): () -> ()
      current.context:checkOwner(owner)
      return function()
        active = false
        if subscription then
          subscription()
          subscription = nil
        end
        for index = #adopted, 1, -1 do
          adopted[index]:dispose()
          adopted[index] = nil
        end
      end
    end)
    local ok, failure = pcall(function()
      if not live() then
        return
      end
      local unsubscribe = lunette.onWindowOpened(function(event: lunette.WindowOpenedEvent)
        if live() then
          place(event.window)
        end
      end)
      subscription = unsubscribe
      if not live() then
        subscription = nil
        unsubscribe()
        return
      end
      for _, window in ipairs(windows(current)) do
        place(window)
      end
    end)
    if not ok then
      effect:dispose()
      error(failure)
    end
    return effect
  end

  return service
end

return init
