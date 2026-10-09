-- Installs a native pose source and adopts windows without closing them.
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local adoption = require '@lunette-contracts/adoption'
local panelsContract = require '@lunette-contracts/panels'
local placementContract = require '@lunette-contracts/placement'
local rulesContract = require '@lunette-contracts/rules'
local vocabulary = require '@lunette-contracts/vocabulary'
local inspection = require '@lunette-contracts/inspection'
local config = require '@lunette-plugins/adoption/config'

export type Service = adoption.Service
export type Owner = adoption.Owner
export type Options = adoption.Options
export type Properties = adoption.Properties
export type Settings = config.Settings

local SOURCE = 'lunette.adoption'

type Adopted = {
  start: {},
  owner: Owner,
  window: lunette.Window,
  panel: panelsContract.WindowPanel,
  placed: plugin.Effect,
}

-- Reads a pose persisted on the window across Lua state reloads.
local function keptPose(window: lunette.Window): rulesContract.Properties?
  local kept = window:getProperty(vocabulary.POSE_PROPERTY)
  if type(kept) ~= 'string' then
    return nil
  end
  return { pose = kept }
end

local function build(context: plugin.Context, settings: Settings): Service
  local records: { inspection.Registration } = {}
  -- A panel destroyed elsewhere has already released its placement, so its entry is only pruned.
  local adopted: { Adopted } = {}
  local function forget(entry: inspection.Registration): ()
    local index = table.find(records, entry)
    if index then
      table.remove(records, index)
    end
  end

  context:effect(function(): () -> ()
    return function()
      table.clear(records)
      table.clear(adopted)
    end
  end)

  local service: Service = {
    inspect = function(_self: Service): inspection.Snapshot
      local result: { inspection.Registration } = {}
      for _, entry in ipairs(records) do
        result[#result + 1] = inspection.registration(
          entry.kind,
          entry.source,
          entry.owner,
          entry.name,
          context:owns(entry.owner),
          entry.details
        )
      end
      for _, entry in ipairs(adopted) do
        if not entry.panel.dead then
          result[#result + 1] = inspection.registration(
            'adoption',
            'adoption.start',
            entry.owner,
            nil,
            context:owns(entry.owner),
            { sourceId = entry.window.id, sourceKind = 'window' }
          )
        end
      end
      return inspection.snapshot(result, { active = context:active() }, { 'filter results require callbacks' })
    end,
    -- The provider registers the source under the caller's ownership; callers do not require the rules service.
    install = function(_self: Service, owner: Owner): plugin.Effect
      context:checkOwner(owner)
      local rules: rulesContract.Service = context:require(rulesContract.capability)
      local chosen = settings.precedence
      return context:acquire(owner, function(): () -> ()
        local registration = rules:addSource(context, { name = SOURCE, precedence = chosen, resolve = keptPose })
        local entry =
          inspection.registration('poseSource', 'adoption.install', owner, SOURCE, true, { precedence = chosen })
        records[#records + 1] = entry
        return function()
          forget(entry)
          registration:dispose()
        end
      end)
    end,
    start = function(_self: Service, owner: Owner, options: Options?): plugin.Effect
      context:checkOwner(owner)
      local panels: panelsContract.Service = context:require(panelsContract.capability)
      local rules: rulesContract.Service = context:require(rulesContract.capability)
      local placement: placementContract.Service = context:require(placementContract.capability)
      local chosen: Options = options or {}
      if chosen.filter ~= nil and type(chosen.filter) ~= 'function' then
        error('adoption: filter is a function of the window, not a ' .. type(chosen.filter), 2)
      end
      local token = {}
      local subscription: (() -> ())?
      local running = true

      -- Copied callbacks run while the start and its caller remain active.
      local function live(): boolean
        return running and context:owns(owner)
      end

      local function place(window: lunette.Window)
        if not live() or window.dead or panels:forSource(window) then
          return
        end
        if chosen.filter and not chosen.filter(window) then
          return
        end
        local resolved = rules:resolve(window)
        local adopt = resolved.adopt
        if adopt == nil and chosen.defaults then
          adopt = chosen.defaults.adopt
        end
        if adopt == false then
          return
        end
        local created, _properties, placed =
          placement:place(context, { window = window, properties = resolved, defaults = chosen.defaults })
        if created.dead or not live() then
          placed:dispose()
          return
        end
        for index = #adopted, 1, -1 do
          if adopted[index].panel.dead then
            table.remove(adopted, index)
          end
        end
        adopted[#adopted + 1] = { start = token, owner = owner, window = window, panel = created, placed = placed }
      end

      local effect = owner:effect(function(): () -> ()
        context:checkOwner(owner)
        local entry =
          inspection.registration('producer', 'adoption.start', owner, nil, true, { filtered = chosen.filter ~= nil })
        records[#records + 1] = entry
        return function()
          forget(entry)
          running = false
          if subscription then
            subscription()
            subscription = nil
          end
          local released: { Adopted } = {}
          for index = #adopted, 1, -1 do
            if adopted[index].start == token then
              table.insert(released, 1, table.remove(adopted, index) :: Adopted)
            end
          end
          -- Release attempts every adoption and raises the first failure.
          local failure: unknown = nil
          for _, entry in ipairs(released) do
            local ok, raised = pcall(entry.placed.dispose, entry.placed)
            if not ok and failure == nil then
              failure = raised
            end
          end
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
          place(event.window)
        end)
        subscription = unsubscribe
        if not live() then
          subscription = nil
          unsubscribe()
          return
        end
        for _, window in ipairs(lunette.windows()) do
          place(window)
        end
      end)
      if not ok then
        effect:dispose()
        error(failure, 0)
      end
      return effect
    end,
  }
  return service
end

return build
