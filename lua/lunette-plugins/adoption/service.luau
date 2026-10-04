-- Installs a native pose source and adopts windows without closing them.
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local adoption = require '@lunette-contracts/adoption'
local panelsContract = require '@lunette-contracts/panels'
local placementContract = require '@lunette-contracts/placement'
local rulesContract = require '@lunette-contracts/rules'
local vocabulary = require '@lunette-contracts/vocabulary'

export type Service = adoption.Service
export type Owner = adoption.Owner
export type Options = adoption.Options
export type Properties = adoption.Properties

local SOURCE = 'lunette.adoption'
local INSTALL_KEYS: { [string]: boolean } = { precedence = true }

type State = {
  active: boolean,
  context: plugin.Context,
}

-- Reads a pose persisted on the window across Lua state reloads.
local function keptPose(window: lunette.Window): rulesContract.Properties?
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

-- The default precedence for the native pose source.
export type Settings = {
  read precedence: number,
}

local function build(context: plugin.Context, settings: Settings): Service
  local state: State = { active = true, context = context }

  -- The source and event callbacks check activation state because copied callbacks can outlive the service.
  context:effect(function(): () -> ()
    return function()
      state.active = false
    end
  end)

  local service: Service = {
    PRECEDENCE = settings.precedence,
    -- The provider registers the source under the caller's ownership; callers do not require the rules service.
    install = function(_self: Service, owner: Owner, options: adoption.InstallOptions?): plugin.Effect
      context:checkOwner(owner)
      if options ~= nil and type(options) ~= 'table' then
        error('adoption: install options are a table of fields, not a ' .. type(options), 2)
      end
      plugin.rejectUnknownFields('adoption install', options or {}, INSTALL_KEYS, 'precedence', 2)
      local rules: rulesContract.Service = context:require(rulesContract.capability)
      local chosen = options and options.precedence or settings.precedence
      if type(chosen) ~= 'number' or chosen ~= chosen then
        error('adoption: precedence is an orderable number', 2)
      end
      local function resolve(window: lunette.Window): rulesContract.Properties?
        if not state.active or not context:active() then
          return nil
        end
        return keptPose(window)
      end
      return context:acquire(owner, function(): () -> ()
        local registration = rules:addSource(context, { name = SOURCE, precedence = chosen, resolve = resolve })
        return function()
          registration:dispose()
        end
      end)
    end,
    start = function(self: Service, owner: Owner, options: Options?): plugin.Effect
      local current = state
      current.context:checkOwner(owner)
      local panels: panelsContract.Service = current.context:require(panelsContract.capability)
      local rules: rulesContract.Service = current.context:require(rulesContract.capability)
      local placement: placementContract.Service = current.context:require(placementContract.capability)
      local settings: Options = options or {}
      if settings.filter ~= nil and type(settings.filter) ~= 'function' then
        error('adoption: filter is a function of the window, not a ' .. type(settings.filter), 2)
      end
      local adopted: { plugin.Effect } = {}
      local adoptedIds: { [number]: boolean } = {}
      local subscription: (() -> ())?
      local active = true

      -- Copied callbacks run while the caller and provider remain active.
      local function live(): boolean
        return active and current.context:owns(owner)
      end

      -- The placement listener runs before the caller-owned release effect is registered.
      local function place(window: lunette.Window)
        if not live() or window.dead or adoptedIds[window.id] or panels:forSource(window) then
          return
        end
        if settings.filter and not settings.filter(window) then
          return
        end
        local resolved = rules:resolve(window)
        local adopt = resolved.adopt
        if adopt == nil and settings.defaults then
          adopt = settings.defaults.adopt
        end
        if adopt == false then
          return
        end
        local created, properties, placed =
          placement:place(current.context, { window = window, properties = resolved, defaults = settings.defaults })
        if created.dead or not live() then
          placed:dispose()
          return
        end
        adoptedIds[window.id] = true
        local acquired: plugin.Effect
        local removal: plugin.Effect? = nil
        local registered, failure = pcall(function(): ()
          acquired = owner:effect(function(): () -> ()
            current.context:checkOwner(owner)
            return function()
              adoptedIds[window.id] = nil
              local index = table.find(adopted, acquired)
              if index then
                table.remove(adopted, index)
              end
              local listener = removal
              removal = nil
              if listener then
                listener:dispose()
              end
              placed:dispose()
            end
          end)
        end)
        if not registered then
          adoptedIds[window.id] = nil
          placed:dispose()
          error(failure, 0)
        end
        removal = panels:onRemoved(current.context, {
          panel = created,
          run = function()
            acquired:dispose()
          end,
        })
        adopted[#adopted + 1] = acquired
        if settings.onPlaced and not created.dead then
          settings.onPlaced(created, properties)
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
          -- Release attempts every adoption and returns the first failure.
          local failure: unknown = nil
          for _, adoption in ipairs(table.clone(adopted)) do
            local ok, raised = pcall(function()
              adoption:dispose()
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
    end,
  }
  return service
end

return build
