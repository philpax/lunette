-- Placements own their panels, visibility overrides, and tag memberships through provider effects.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local panelsContract = require '@lunette-contracts/panels'
local contract = require '@lunette-contracts/placement'
local rulesContract = require '@lunette-contracts/rules'
local tagsContract = require '@lunette-contracts/tags'
local vocabulary = require '@lunette-contracts/vocabulary'
local listeners = require '@lunette-plugins/listeners'
local inspection = require '@lunette-contracts/inspection'
local config = require '@lunette-plugins/placement/config'

local service = {}

type Owner = contract.Owner
type Properties = contract.Properties
type Tag = tagsContract.Tag

export type PanelOptionsBase = config.PanelOptionsBase
export type PanelOptions = config.PanelOptions
export type Settings = config.Settings

type Record = { placement: contract.Placement, owner: Owner }

type State = {
  context: plugin.Context,
  settings: Settings,
  placements: { Record },
  listeners: listeners.Listeners<(contract.Placement) -> ()>,
}

local REQUEST_KEYS: { [string]: boolean } = { window = true, properties = true, defaults = true }
local LISTENER_KEYS: { [string]: boolean } = { run = true }

local function report(message: string, level: ('info' | 'warn')?): ()
  local log = lovr.log
  if log then
    log(message, level or 'warn', 'lunette.placement')
  end
end

local function poseFrom(value: (string | Mat4)?, window: lunette.Window): Mat4?
  if type(value) ~= 'string' then
    return value
  end
  local decoded = vocabulary.decodePose(value)
  if not decoded then
    report("the pose for '" .. tostring(window.appId) .. "' is not sixteen numbers, so it is ignored")
  end
  return decoded
end

function service.panelOptions(properties: Properties, window: lunette.Window): panelsContract.Options
  return {
    pose = poseFrom(properties.pose, window),
    width = properties.width,
    height = properties.height,
    title = properties.title,
    priority = properties.priority,
    chrome = properties.chrome,
    curve = properties.curve,
  }
end

local function joinTags(
  state: State,
  created: panelsContract.WindowPanel,
  names: { read [number]: string },
  holds: { plugin.Effect },
  memberships: { Tag }
): ()
  local tags: tagsContract.Service = state.context:require(tagsContract.capability)
  for index = 1, #names do
    local named: unknown = names[index]
    if type(named) == 'string' then
      if not tags:find(named) then
        report("nothing declared the tag '" .. named .. "', so it was created", 'info')
      end
      local tag, held = tags:hold(state.context, { name = named })
      holds[#holds + 1] = held
      if tag:add(state.context, created) then
        memberships[#memberships + 1] = tag
      end
    else
      report('a tag is named by a string, not a ' .. type(named))
    end
  end
end

local function acquire(
  state: State,
  owner: Owner,
  window: lunette.Window,
  properties: Properties
): (panelsContract.WindowPanel, plugin.Effect)
  local context = state.context
  local panels: panelsContract.Service = context:require(panelsContract.capability)
  local created: panelsContract.WindowPanel?
  local holds: { plugin.Effect } = {}
  local memberships: { Tag } = {}
  local hiding: plugin.Effect? = nil
  local removal: plugin.Effect? = nil
  -- Every step is attempted once, and the failures are raised together.
  local function cleanup()
    local failures: { string } = {}
    local function attempt(operation: string, action: () -> ())
      local ok, failure = pcall(action)
      if not ok then
        failures[#failures + 1] = operation .. ': ' .. tostring(failure)
      end
    end
    local listener = removal
    if listener then
      attempt('stop removal listener', function()
        listener:dispose()
      end)
    end
    local panel = created
    if panel then
      for index = #state.placements, 1, -1 do
        if state.placements[index].placement.panel == panel then
          table.remove(state.placements, index)
        end
      end
      for index = #memberships, 1, -1 do
        local tag = memberships[index]
        attempt('remove membership', function()
          tag:remove(context, panel)
        end)
      end
      local hidden = hiding
      if hidden then
        attempt('show panel', function()
          hidden:dispose()
        end)
      end
      attempt('destroy panel', function()
        panel:destroy(context)
      end)
    end
    for index = #holds, 1, -1 do
      local effect = holds[index]
      attempt('release tag', function()
        effect:dispose()
      end)
    end
    if #failures > 0 then
      error('placement: cleanup: ' .. table.concat(failures, '; '))
    end
  end
  local panel, acquired = context:resource(owner, function(): (panelsContract.WindowPanel, () -> ())
    local ok, result = pcall(function()
      -- schema.callback uses PanelOptions; naming it avoids comparing the schema's cloned recursive types.
      local panelOptions = state.settings.panelOptions :: config.PanelOptions
      local options = panelOptions(properties, window, service.panelOptions)
      if type(options) ~= 'table' then
        error('placement: panelOptions answered a ' .. type(options) .. ', not panel options')
      end
      local panel = panels:fromWindow(context, window, options)
      created = panel
      if properties.hidden == true then
        hiding = panel:setHidden(context, { hidden = true })
      end
      if properties.tags then
        joinTags(state, panel, properties.tags, holds, memberships)
      end
      return panel
    end)
    if not ok then
      local cleaned, cleanupFailure = pcall(cleanup)
      if not cleaned then
        error('placement: acquisition: ' .. tostring(result) .. '; ' .. tostring(cleanupFailure))
      end
      error(result)
    end
    return result, cleanup
  end)
  if panel.dead then
    acquired:dispose()
  else
    -- Panel removal ends the placement and its tag memberships.
    removal = panels:onRemoved(context, {
      panel = panel,
      run = function()
        acquired:dispose()
      end,
    })
  end
  return panel, acquired
end

local function checkedRequest(request: unknown): contract.Request
  plugin.rejectUnknownFields('placement place', request, REQUEST_KEYS, 'window, properties, and defaults', 3)
  local checked = request :: contract.Request
  if checked.window == nil then
    error('placement: a window is placed, and nil is not one', 3)
  end
  if checked.properties ~= nil and type(checked.properties) ~= 'table' then
    error('placement: properties are a table, not a ' .. type(checked.properties), 3)
  end
  if checked.defaults ~= nil and type(checked.defaults) ~= 'table' then
    error('placement: defaults are a table, not a ' .. type(checked.defaults), 3)
  end
  return checked
end

function service.build(context: plugin.Context, settings: Settings): contract.Service
  local state: State = {
    context = context,
    settings = settings,
    placements = {},
    listeners = listeners.new<<(contract.Placement) -> ()>>(context),
  }

  local function announce(placed: contract.Placement): ()
    state.listeners:each('placement: a placement listener', function(run: (contract.Placement) -> ()): ()
      run(placed)
    end, function(): boolean
      return not placed.panel.dead
    end)
  end

  local implementation: contract.Service = {
    inspect = function(_self: contract.Service): inspection.Snapshot
      local result = state.listeners:inspect 'placement.onPlaced'
      for _, record in ipairs(state.placements) do
        local owner, placed = record.owner, record.placement
        local target = placed.panel
        result[#result + 1] = inspection.registration(
          'placement',
          'placement.place',
          owner,
          target.title,
          context:owns(owner) and not target.dead,
          {
            sourceId = target.source.id,
            sourceKind = target.kind,
            initialPose = placed.properties.pose ~= nil,
            hidden = target.hidden,
          }
        )
      end
      return inspection.snapshot(result, nil, { 'resolved property provenance is not retained' })
    end,
    place = function(
      _self: contract.Service,
      owner: Owner,
      request: contract.Request
    ): (panelsContract.WindowPanel, Properties, plugin.Effect)
      local checked = checkedRequest(request)
      context:checkOwner(owner)
      local window = checked.window
      local resolved: Properties = checked.properties
        or (context:require(rulesContract.capability) :: rulesContract.Service):resolve(window)
      local properties: { [string]: unknown } = table.clone(resolved :: any)
      for key, value in pairs(checked.defaults or {}) do
        if properties[key] == nil then
          properties[key] = value
        end
      end
      local frozen: Properties = table.freeze(properties) :: any
      local panel, effect = acquire(state, owner, window, frozen)
      if panel.dead then
        return panel, frozen, effect
      end
      local placed: contract.Placement = table.freeze { panel = panel, properties = frozen }
      state.placements[#state.placements + 1] = { placement = placed, owner = owner }
      announce(placed)
      return panel, frozen, effect
    end,
    placed = function(_self: contract.Service): { contract.Placement }
      local result: { contract.Placement } = {}
      for _, record in ipairs(state.placements) do
        if not record.placement.panel.dead then
          result[#result + 1] = record.placement
        end
      end
      return result
    end,
    onPlaced = function(_self: contract.Service, owner: Owner, listener: contract.PlacedListener): plugin.Effect
      plugin.rejectUnknownFields('placement onPlaced', listener, LISTENER_KEYS, 'run', 2)
      if type(listener.run) ~= 'function' then
        error('placement: onPlaced run is a function, not a ' .. type(listener.run), 2)
      end
      return state.listeners:add(owner, listener.run)
    end,
  }
  return implementation
end

return service
