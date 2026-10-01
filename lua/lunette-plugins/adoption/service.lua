-- Scoped native-window adoption over the panels and rules providers.
--
-- Installation is deliberately separate from startup. Installation contributes
-- only the native pose source; startup owns the event subscription and every
-- panel it creates. Native windows remain caller-owned and are never closed.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local adoption = require '@lunette-contracts/adoption'
local panelsContract = require '@lunette-contracts/panels'
local rulesContract = require '@lunette-contracts/rules'
local vocabulary = require '@lunette-contracts/vocabulary'

export type Service = adoption.Service
export type Owner = adoption.Owner
export type Options = adoption.Options
export type Properties = adoption.Properties

local SOURCE = 'lunette.adoption'
local PRECEDENCE = 300

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

local function checkWindow(window: lunette.Window)
  local kind = type(window)
  if kind ~= 'table' and kind ~= 'userdata' then
    error('adoption: a window carries the properties, and a ' .. kind .. ' does not', 3)
  end
end

local function properties(state: State, window: lunette.Window): rulesContract.Resolved?
  checkWindow(window)
  local kept = window:getProperty(vocabulary.POSE_PROPERTY)
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

  -- The published service is revoked with this activation, so its methods
  -- need no liveness guard. The source closure and event callbacks are not
  -- reached through the service, and they check the activation themselves.
  context:effect(function(): () -> ()
    return function()
      state.active = false
    end
  end)

  function implementation.properties(_self: Service, window: lunette.Window): rulesContract.Resolved?
    return properties(state, window)
  end

  function implementation.source(_self: Service): (lunette.Window) -> Properties?
    return source(state)
  end

  -- The source is registered under this provider's own rules binding, inside
  -- an effect on the caller's owner. The caller's lifetime still bounds the
  -- registration, and the caller does not need to require rules itself.
  function implementation.install(self: Service, owner: Owner, precedence: number?): plugin.Effect
    context:checkOwner(owner)
    local rules: rulesContract.Service = context:require(rulesContract.capability)
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
    return context:acquire(owner, function(): () -> ()
      local registration = rules:addSource(context, SOURCE, chosen, resolve)
      return function()
        registration:dispose()
      end
    end)
  end

  function implementation.windows(_self: Service): { lunette.Window }
    return windows(state)
  end

  function implementation.start(self: Service, owner: Owner, options: Options?): plugin.Effect
    local current = state
    current.context:checkOwner(owner)
    local panels: panelsContract.Service = current.context:require(panelsContract.capability)
    local rules: rulesContract.Service = current.context:require(rulesContract.capability)
    local settings: Options = options or {}
    local adopted: { plugin.Effect } = {}
    local adoptedIds: { [number]: boolean } = {}
    local subscription: (() -> ())?
    local active = true

    -- Copied callbacks must still belong to this provider's caller
    -- activation, and owns also requires this provider to be active.
    local function live(): boolean
      return active and current.context:owns(owner)
    end

    -- An adoption ends with its panel. The removal listener and the rules
    -- placement belong to this provider and are released by the adoption's
    -- inverse on the caller's owner, so neither outlives the window's panel and
    -- the caller holds no effect for a window that is gone.
    local function place(window: lunette.Window)
      if not live() or window.dead or adoptedIds[window.id] or panels:forSource(window) then
        return
      end
      local panel: panelsContract.WindowPanel?
      local resolved: rulesContract.Resolved?
      local acquired: plugin.Effect
      acquired = owner:effect(function(): () -> ()
        current.context:checkOwner(owner)
        adoptedIds[window.id] = true
        local created, properties, placed = rules:place(current.context, window, settings.defaults)
        panel, resolved = created, properties
        local removal = panels:onRemoved(current.context, created, function()
          acquired:dispose()
        end)
        return function()
          adoptedIds[window.id] = nil
          local index = table.find(adopted, acquired)
          if index then
            table.remove(adopted, index)
          end
          removal:dispose()
          placed:dispose()
        end
      end)
      local created = assert(panel)
      if not live() or created.dead then
        acquired:dispose()
        return
      end
      adopted[#adopted + 1] = acquired
      if settings.onPlaced then
        settings.onPlaced(created, assert(resolved))
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
        -- Every adoption is released before the first failure is raised.
        local failure: unknown = nil
        for _, placement in ipairs(table.clone(adopted)) do
          local ok, raised = pcall(function()
            placement:dispose()
          end)
          if not ok and failure == nil then
            failure = raised
          end
        end
        table.clear(adopted)
        if failure ~= nil then
          error(failure, 0)
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
