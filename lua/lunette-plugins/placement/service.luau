-- Placements own their panels, visibility overrides, and tag memberships through provider effects.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local panelsContract = require '@lunette-contracts/panels'
local contract = require '@lunette-contracts/placement'
local rulesContract = require '@lunette-contracts/rules'
local tagsContract = require '@lunette-contracts/tags'
local vocabulary = require '@lunette-contracts/vocabulary'
local listeners = require '@lunette-plugins/listeners'

local service = {}

type Owner = contract.Owner
type Properties = contract.Properties
type Tag = tagsContract.Tag

export type PanelOptionsBase = (Properties, lunette.Window) -> panelsContract.Options
export type PanelOptions = (Properties, lunette.Window, PanelOptionsBase) -> panelsContract.Options

export type Settings = {
  read panelOptions: PanelOptions,
}

type State = {
  context: plugin.Context,
  settings: Settings,
  placements: { contract.Placement },
  listeners: listeners.Listeners<(contract.Placement) -> ()>,
}

local REQUEST_KEYS: { [string]: boolean } = { window = true, properties = true, defaults = true }
local LISTENER_KEYS: { [string]: boolean } = { run = true }

local function report(message: string, level: rulesContract.LogLevel?): ()
  if lovr and lovr.log then
    lovr.log(message, level or 'warn', 'lunette.placement')
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

-- String tag names are held, creating a tag when needed; tag values are joined directly.
local function joinTags(
  state: State,
  created: panelsContract.WindowPanel,
  names: { read [number]: string | Tag },
  holds: { plugin.Effect },
  memberships: { Tag }
): ()
  local tags: tagsContract.Service = state.context:require(tagsContract.capability)
  for index = 1, #names do
    local named = names[index]
    local found: Tag?
    if type(named) == 'string' then
      if not tags:find(named) then
        report("nothing declared the tag '" .. named .. "', so it was created", 'info')
      end
      local tag, held = tags:hold(state.context, { name = named })
      found = tag
      holds[#holds + 1] = held
    elseif tags:isTag(named) then
      found = named
    else
      report('a tag is named by a string or is a tag, not a ' .. type(named))
    end
    if found and found:add(state.context, created) then
      memberships[#memberships + 1] = found
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
  local function cleanup()
    local panel = created
    local added = memberships
    local held = holds
    local hidden = hiding
    local listener = removal
    created = nil
    memberships = {}
    holds = {}
    hiding = nil
    removal = nil
    local failures: { string } = {}
    local function attempt(operation: string, action: () -> ())
      local ok, failure = pcall(action)
      if not ok then
        failures[#failures + 1] = operation .. ': ' .. tostring(failure)
      end
    end
    if listener then
      attempt('stop removal listener', function()
        listener:dispose()
      end)
    end
    if panel then
      for index = #state.placements, 1, -1 do
        if state.placements[index].panel == panel then
          table.remove(state.placements, index)
        end
      end
      for index = #added, 1, -1 do
        local tag = added[index]
        added[index] = nil
        attempt('remove membership', function()
          tag:remove(context, panel)
        end)
      end
      if hidden then
        attempt('show panel', function()
          hidden:dispose()
        end)
      end
      attempt('destroy panel', function()
        panel:destroy(context)
      end)
    end
    for index = #held, 1, -1 do
      local effect = held[index]
      held[index] = nil
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
      local options = state.settings.panelOptions(properties, window, service.panelOptions)
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
  if type(request) ~= 'table' then
    error('placement: a request is a table of fields, not a ' .. type(request), 3)
  end
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
      state.placements[#state.placements + 1] = placed
      announce(placed)
      return panel, frozen, effect
    end,
    placed = function(_self: contract.Service): { contract.Placement }
      local result: { contract.Placement } = {}
      for _, placed in ipairs(state.placements) do
        if not placed.panel.dead then
          result[#result + 1] = placed
        end
      end
      return result
    end,
    onPlaced = function(_self: contract.Service, owner: Owner, listener: contract.PlacedListener): plugin.Effect
      if type(listener) ~= 'table' then
        error('placement: onPlaced takes a table of fields, not a ' .. type(listener), 2)
      end
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
