-- The RULES provider. Matching and resolving are pure queries over an activation's
-- ordered source registry; registrations and placement are owner-scoped.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local contracts = require '@lunette-contracts/rules'
local panelsContract = require '@lunette-contracts/panels'
local tagsContract = require '@lunette-contracts/tags'
local pose = require '@mullion/pose'
local policy = require '@lunette-plugins/rules/policy'
local panelEvents = require '@lunette-plugins/panels/events'

export type Service = contracts.Service
export type Owner = contracts.Owner
export type Properties = contracts.Properties
export type Resolved = contracts.Resolved
export type Rule = contracts.Rule
export type Tag = contracts.Tag

type Source = contracts.Source & {
  resolve: (lunette.Window) -> Properties?,
  sequence: number,
  cleanup: plugin.Effect?,
}

type ProviderState = {
  context: plugin.Context,
  service: Service,
  sources: { Source },
  registrations: number,
}

type MutableService = {
  DEFAULT_PRECEDENCE: number,
  DEFAULT_SOURCE: string,
  PANEL_PROPERTIES: { string },
  report: (Service, string, string?) -> (),
  addSource: (Service, Owner, string, number, (lunette.Window) -> Properties?) -> plugin.Effect,
  sources: (Service) -> { contracts.Source },
  fromList: (Service, { Rule }) -> (lunette.Window) -> Properties?,
  setRules: (Service, Owner, { Rule }) -> plugin.Effect,
  matches: (Service, contracts.Match?, lunette.Window) -> boolean,
  resolve: (Service, lunette.Window) -> Resolved,
  place: (Service, Owner, lunette.Window, Resolved?) -> (panelsContract.WindowPanel, Resolved),
}

local function byPrecedence(left: Source, right: Source): boolean
  if left.precedence ~= right.precedence then
    return left.precedence < right.precedence
  end
  return left.sequence < right.sequence
end

local function orderedSources(state: ProviderState): { Source }
  local ordered: { Source } = {}
  for index, source in ipairs(state.sources) do
    ordered[index] = source
  end
  table.sort(ordered, byPrecedence)
  return ordered
end

local function removeSource(state: ProviderState, target: Source): boolean
  for index, source in ipairs(state.sources) do
    if source == target then
      table.remove(state.sources, index)
      return true
    end
  end
  return false
end

local layer = policy.layer
local evaluate = policy.evaluate

local function matches(_self: Service, match: contracts.Match?, window: lunette.Window): boolean
  return policy.matches(match, window)
end

local function checkedRules(service: Service, list: { Rule }): { Rule }
  if type(list) ~= 'table' then
    error('rules: a rules list is a table, not a ' .. type(list), 3)
  end
  local checked: { Rule } = {}
  for index, rule in ipairs(list) do
    if type(rule) ~= 'table' then
      error('rules: rule ' .. index .. ' is a table, not a ' .. type(rule), 3)
    end
    if rule.match ~= nil and type(rule.match) ~= 'table' then
      error('rules: the match of rule ' .. index .. ' is a table, not a ' .. type(rule.match), 3)
    end
    if rule.properties ~= nil and type(rule.properties) ~= 'table' then
      error('rules: the properties of rule ' .. index .. ' are a table, not a ' .. type(rule.properties), 3)
    end
    checked[index] = rule
  end
  return checked
end

local function fromList(service: Service, list: { Rule }): (lunette.Window) -> Properties?
  local checked = checkedRules(service, list)
  return function(window: lunette.Window): Properties?
    local collected: Properties? = nil
    for _, rule in ipairs(checked) do
      if rule.properties and service:matches(rule.match, window) then
        collected = layer(collected or {}, rule.properties)
      end
    end
    return collected
  end
end

local function report(state: ProviderState, message: string, level: string?): ()
  if lovr and lovr.log then
    lovr.log(message, level or 'warn', 'lunette.rules')
  end
end

local function poseFrom(state: ProviderState, value: (string | Mat4)?, window: lunette.Window): Mat4?
  if type(value) ~= 'string' then
    return value
  end
  local decoded = pose.decode(value)
  if not decoded then
    report(state, "the pose for '" .. tostring(window.appId) .. "' is not sixteen numbers, so it is ignored")
  end
  return decoded
end

local function applyTags(
  state: ProviderState,
  created: panelsContract.WindowPanel,
  names: { read [number]: string | Tag },
  made: { Tag },
  memberships: { Tag }
): ()
  local tags: tagsContract.Service = state.context:require(tagsContract.capability)
  for index = 1, #names do
    local named = names[index]
    local found: Tag?
    if type(named) == 'string' then
      found = tags:find(named)
      if not found then
        local acquired = tags:new(state.context, named)
        found = acquired
        made[#made + 1] = acquired
        report(state, "nothing declared the tag '" .. named .. "', so it was created", 'info')
      end
    elseif tags:isTag(named) then
      found = named
    else
      report(state, 'a tag is named by a string or is a tag, not a ' .. type(named))
    end
    if found and found:add(created) then
      memberships[#memberships + 1] = found
    end
  end
end

local function acquirePlacement(
  state: ProviderState,
  owner: Owner,
  window: lunette.Window,
  properties: Resolved
): panelsContract.WindowPanel
  local panels: panelsContract.Service = state.context:require(panelsContract.capability)
  local created: panelsContract.WindowPanel?
  local made: { Tag } = {}
  local memberships: { Tag } = {}
  local function cleanup()
    local panel = created
    local added = memberships
    local owned = made
    created = nil
    memberships = {}
    made = {}
    local failures: { string } = {}
    local function attempt(operation: string, action: () -> ())
      local ok, failure = pcall(action)
      if not ok then
        failures[#failures + 1] = operation .. ': ' .. tostring(failure)
      end
    end
    if panel then
      panelEvents.detachCleanup(panel)
      for index = #added, 1, -1 do
        local tag = added[index]
        added[index] = nil
        attempt('remove membership', function()
          tag:remove(panel)
        end)
      end
      attempt('destroy panel', function()
        panel:destroy()
      end)
    end
    for index = #owned, 1, -1 do
      local tag = owned[index]
      owned[index] = nil
      attempt('destroy implicit tag', function()
        tag:destroy()
      end)
    end
    if #failures > 0 then
      error('rules: placement cleanup: ' .. table.concat(failures, '; '))
    end
  end
  local acquired = owner:effect(function(): () -> ()
    state.context:checkOwner(owner)
    local ok, failure = pcall(function()
      local panel = panels:fromWindow(state.context, window, {
        pose = poseFrom(state, properties.pose, window),
        width = properties.width,
        height = properties.height,
        title = properties.title,
        priority = properties.priority,
        chrome = properties.chrome,
      })
      created = panel
      if properties.tags then
        applyTags(state, panel, properties.tags, made, memberships)
      end
    end)
    if not ok then
      local cleaned, cleanupFailure = pcall(cleanup)
      if not cleaned then
        error('rules: placement acquisition: ' .. tostring(failure) .. '; ' .. tostring(cleanupFailure))
      end
      error(failure)
    end
    return cleanup
  end)
  local panel = assert(created)
  if panel.dead then
    acquired:dispose()
  else
    panelEvents.attachCleanup(panel, function()
      acquired:dispose()
    end)
  end
  return panel
end

local function init(context: plugin.Context): Service
  local implementation: MutableService = {
    DEFAULT_PRECEDENCE = 100,
    DEFAULT_SOURCE = 'lunette.rules',
    PANEL_PROPERTIES = { 'pose', 'width', 'height', 'title', 'priority', 'chrome' },
    report = function(_self: Service, _message: string, _level: string?) end,
    addSource = function(
      _self: Service,
      _owner: Owner,
      _name: string,
      _precedence: number,
      _resolve: (lunette.Window) -> Properties?
    ): plugin.Effect
      error 'rules: service is not initialized'
    end,
    sources = function(_self: Service): { contracts.Source }
      error 'rules: service is not initialized'
    end,
    fromList = function(_self: Service, _list: { Rule }): (lunette.Window) -> Properties?
      error 'rules: service is not initialized'
    end,
    setRules = function(_self: Service, _owner: Owner, _list: { Rule }): plugin.Effect
      error 'rules: service is not initialized'
    end,
    matches = function(_self: Service, _match: contracts.Match?, _window: lunette.Window): boolean
      error 'rules: service is not initialized'
    end,
    resolve = function(_self: Service, _window: lunette.Window): Resolved
      error 'rules: service is not initialized'
    end,
    place = function(
      _self: Service,
      _owner: Owner,
      _window: lunette.Window,
      _options: Resolved?
    ): (panelsContract.WindowPanel, Resolved)
      error 'rules: service is not initialized'
    end,
  }
  local service: Service = implementation
  local state: ProviderState = {
    context = context,
    service = service,
    sources = {},
    registrations = 0,
  }

  -- The published service is revoked with this activation, so its methods
  -- need no liveness guard of their own.
  context:effect(function(): () -> ()
    return function()
      state.sources = {}
      state.registrations = 0
    end
  end)

  function implementation.report(_self: Service, message: string, level: string?)
    report(state, message, level)
  end

  function implementation.addSource(
    _self: Service,
    owner: Owner,
    name: string,
    precedence: number,
    resolve: (lunette.Window) -> Properties?
  ): plugin.Effect
    context:checkOwner(owner)
    if type(name) ~= 'string' then
      error('rules: a source is named by a string, not a ' .. type(name), 2)
    end
    if type(precedence) ~= 'number' or precedence ~= precedence then
      error('rules: the precedence of a source is an orderable number', 2)
    end
    if type(resolve) ~= 'function' then
      error('rules: a source resolver is a function, not a ' .. type(resolve), 2)
    end

    local registered: Source?
    local effect = owner:effect(function(): () -> ()
      context:checkOwner(owner)
      for index = #state.sources, 1, -1 do
        local previous = state.sources[index]
        if previous.name == name then
          table.remove(state.sources, index)
          if previous.cleanup then
            previous.cleanup:dispose()
          end
        end
      end
      state.registrations += 1
      local source: Source = {
        name = name,
        precedence = precedence,
        resolve = resolve,
        sequence = state.registrations,
        cleanup = nil,
      }
      registered = source
      state.sources[#state.sources + 1] = source
      return function(): ()
        if registered then
          removeSource(state, registered)
          registered = nil
        end
      end
    end)
    if registered then
      registered.cleanup = effect
    end
    return effect
  end

  function implementation.sources(_self: Service): { contracts.Source }
    local described: { contracts.Source } = {}
    for index, source in ipairs(orderedSources(state)) do
      described[index] = { name = source.name, precedence = source.precedence }
    end
    return described
  end

  function implementation.fromList(_self: Service, list: { Rule }): (lunette.Window) -> Properties?
    return fromList(service, list)
  end

  function implementation.setRules(_self: Service, owner: Owner, list: { Rule }): plugin.Effect
    return service:addSource(owner, service.DEFAULT_SOURCE, service.DEFAULT_PRECEDENCE, service:fromList(list))
  end

  function implementation.matches(_self: Service, match: contracts.Match?, window: lunette.Window): boolean
    return matches(service, match, window)
  end

  function implementation.resolve(_self: Service, window: lunette.Window): Resolved
    local collected: Properties = {}
    for _, source in ipairs(orderedSources(state)) do
      local answered = source.resolve(window)
      if answered ~= nil then
        if type(answered) ~= 'table' then
          error("rules: the source '" .. source.name .. "' answered a " .. type(answered) .. ', not a table')
        end
        layer(collected, answered)
      end
    end
    return evaluate(collected, window)
  end

  function implementation.place(
    _self: Service,
    owner: Owner,
    window: lunette.Window,
    options: Resolved?
  ): (panelsContract.WindowPanel, Resolved)
    if window == nil then
      error('rules: a window is placed, and nil is not one', 2)
    end
    context:checkOwner(owner)
    local properties = service:resolve(window)
    if options then
      for key, value in pairs(options) do
        if properties[key] == nil then
          properties[key] = value
        end
      end
    end
    local panel = acquirePlacement(state, owner, window, properties)
    return panel, properties
  end

  return service
end

return init
