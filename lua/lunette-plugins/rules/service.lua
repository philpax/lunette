-- The RULES provider. Matching and resolving are pure queries over an activation's
-- ordered source registry; registrations and placement are owner-scoped. A
-- placement ends when its owner disposes it or unloads, or when its panel is
-- removed for any reason, which the panels contract announces.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local contracts = require '@lunette-contracts/rules'
local panelsContract = require '@lunette-contracts/panels'
local tagsContract = require '@lunette-contracts/tags'
local vocabulary = require '@lunette-contracts/vocabulary'
local policy = require '@lunette-plugins/rules/policy'

export type Service = contracts.Service
export type Owner = contracts.Owner
export type Properties = contracts.Properties
export type Resolved = contracts.Resolved
export type Rule = contracts.Rule
export type Tag = contracts.Tag

type Source = contracts.Source & {
  resolve: (lunette.Window) -> Properties?,
  sequence: number,
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
  report: (Service, contracts.Report) -> (),
  addSource: (Service, Owner, contracts.SourceRegistration) -> plugin.Effect,
  sources: (Service) -> { contracts.Source },
  fromList: (Service, { Rule }) -> (lunette.Window) -> Properties?,
  setRules: (Service, Owner, contracts.RuleSet) -> plugin.Effect,
  matches: (Service, contracts.Match?, lunette.Window) -> boolean,
  resolve: (Service, lunette.Window) -> Resolved,
  place: (Service, Owner, lunette.Window, Resolved?) -> (panelsContract.WindowPanel, Resolved, plugin.Effect),
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
  -- A key outside the list's positions would be skipped by ipairs, so a rule
  -- under one would be dropped without a word.
  local count = rawlen(list)
  for key, _ in list :: { [unknown]: unknown } do
    if type(key) ~= 'number' or key ~= math.floor(key) or key < 1 or key > count then
      error('rules: a rules list is a list, and ' .. tostring(key) .. ' is not one of its positions', 3)
    end
  end
  local checked: { Rule } = {}
  for index = 1, count do
    local rule = list[index]
    if type(rule) ~= 'table' then
      error('rules: rule ' .. index .. ' is a table, not a ' .. type(rule), 3)
    end
    for key, _ in rule :: { [unknown]: unknown } do
      if key ~= 'match' and key ~= 'properties' then
        error(
          'rules: rule '
            .. index
            .. ' has an unknown field '
            .. tostring(key)
            .. '; the fields are match and properties',
          3
        )
      end
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

local function report(state: ProviderState, message: string, level: contracts.LogLevel?): ()
  if lovr and lovr.log then
    lovr.log(message, level or 'warn', 'lunette.rules')
  end
end

local function poseFrom(state: ProviderState, value: (string | Mat4)?, window: lunette.Window): Mat4?
  if type(value) ~= 'string' then
    return value
  end
  local decoded = vocabulary.decodePose(value)
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
    if found and found:add(state.context, created) then
      memberships[#memberships + 1] = found
    end
  end
end

local function acquirePlacement(
  state: ProviderState,
  owner: Owner,
  window: lunette.Window,
  properties: Resolved
): (panelsContract.WindowPanel, plugin.Effect)
  local panels: panelsContract.Service = state.context:require(panelsContract.capability)
  local created: panelsContract.WindowPanel?
  local made: { Tag } = {}
  local memberships: { Tag } = {}
  local removal: plugin.Effect? = nil
  local function cleanup()
    local panel = created
    local added = memberships
    local owned = made
    local listener = removal
    created = nil
    memberships = {}
    made = {}
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
      for index = #added, 1, -1 do
        local tag = added[index]
        added[index] = nil
        attempt('remove membership', function()
          tag:remove(state.context, panel)
        end)
      end
      attempt('destroy panel', function()
        panel:destroy(state.context)
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
        curve = properties.curve,
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
    -- The listener belongs to this provider and is stopped by the cleanup, so a
    -- panel removed by its source dying or by the panels provider ends the
    -- placement it belongs to.
    removal = panels:onRemoved(state.context, {
      panel = panel,
      run = function()
        acquired:dispose()
      end,
    })
  end
  return panel, acquired
end

-- The resolved options: the precedence a rule set takes when it names none.
export type Settings = {
  read precedence: number,
}

local function build(context: plugin.Context, settings: Settings): Service
  local implementation: MutableService = {
    DEFAULT_PRECEDENCE = settings.precedence,
    DEFAULT_SOURCE = 'lunette.rules',
    PANEL_PROPERTIES = { 'pose', 'width', 'height', 'title', 'priority', 'chrome', 'curve' },
    report = function(_self: Service, _report: contracts.Report) end,
    addSource = function(_self: Service, _owner: Owner, _registration: contracts.SourceRegistration): plugin.Effect
      error 'rules: service is not initialized'
    end,
    sources = function(_self: Service): { contracts.Source }
      error 'rules: service is not initialized'
    end,
    fromList = function(_self: Service, _list: { Rule }): (lunette.Window) -> Properties?
      error 'rules: service is not initialized'
    end,
    setRules = function(_self: Service, _owner: Owner, _set: contracts.RuleSet): plugin.Effect
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
    ): (panelsContract.WindowPanel, Resolved, plugin.Effect)
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

  function implementation.report(_self: Service, fields: contracts.Report)
    if type(fields) ~= 'table' or type(fields.message) ~= 'string' then
      error('rules report: a report is a table whose message is a string', 2)
    end
    report(state, fields.message, fields.level)
  end

  function implementation.addSource(
    _self: Service,
    owner: Owner,
    registration: contracts.SourceRegistration
  ): plugin.Effect
    context:checkOwner(owner)
    if type(registration) ~= 'table' then
      error('rules: a source registration is a table of fields, not a ' .. type(registration), 2)
    end
    for key, _ in registration :: { [unknown]: unknown } do
      if key ~= 'name' and key ~= 'precedence' and key ~= 'resolve' then
        error('rules: unknown source field ' .. tostring(key) .. '; the fields are name, precedence, and resolve', 2)
      end
    end
    local name, precedence, resolve = registration.name, registration.precedence, registration.resolve
    if type(name) ~= 'string' then
      error('rules: a source is named by a string, not a ' .. type(name), 2)
    end
    if type(precedence) ~= 'number' or precedence ~= precedence then
      error('rules: the precedence of a source is an orderable number', 2)
    end
    if type(resolve) ~= 'function' then
      error('rules: a source resolver is a function, not a ' .. type(resolve), 2)
    end

    -- A name names one registration. Replacing another owner's source would
    -- end a resource that owner still holds, so a duplicate raises; an owner
    -- replaces its own source by disposing it first.
    for _, previous in ipairs(state.sources) do
      if previous.name == name then
        error("rules: a source named '" .. name .. "' is already registered", 2)
      end
    end
    local registered: Source?
    local effect = owner:effect(function(): () -> ()
      context:checkOwner(owner)
      state.registrations += 1
      local source: Source = {
        name = name,
        precedence = precedence,
        resolve = resolve,
        sequence = state.registrations,
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

  function implementation.setRules(_self: Service, owner: Owner, set: contracts.RuleSet): plugin.Effect
    if type(set) ~= 'table' then
      error('rules: a rule set is a table of fields, not a ' .. type(set), 2)
    end
    for key, _ in set :: { [unknown]: unknown } do
      if key ~= 'name' and key ~= 'precedence' and key ~= 'rules' then
        error('rules: unknown rule set field ' .. tostring(key) .. '; the fields are name, precedence, and rules', 2)
      end
    end
    if type(set.rules) ~= 'table' then
      error('rules: a rule set has a list of rules, not a ' .. type(set.rules), 2)
    end
    return service:addSource(owner, {
      name = set.name or service.DEFAULT_SOURCE,
      precedence = set.precedence or service.DEFAULT_PRECEDENCE,
      resolve = service:fromList(set.rules),
    })
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
  ): (panelsContract.WindowPanel, Resolved, plugin.Effect)
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
    local panel, placement = acquirePlacement(state, owner, window, properties)
    return panel, properties, placement
  end

  return service
end

return build
