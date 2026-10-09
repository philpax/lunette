-- Rule sources are activation-scoped and ordered. Placement policy is applied by lunette/placement.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local contracts = require '@lunette-contracts/rules'
local policy = require '@lunette-plugins/rules/policy'
local inspection = require '@lunette-contracts/inspection'

export type Service = contracts.Service
export type Owner = contracts.Owner
export type Properties = contracts.Properties
export type Resolved = contracts.Resolved
export type Rule = contracts.Rule

type Source = {
  name: string,
  precedence: number,
  owner: Owner,
  resolve: (lunette.Window) -> Properties?,
  sequence: number,
}

type ProviderState = {
  context: plugin.Context,
  sources: { Source },
  registrations: number,
}

local SOURCE_KEYS: { [string]: boolean } = { name = true, precedence = true, resolve = true }
local RULE_SET_KEYS: { [string]: boolean } = { name = true, precedence = true, rules = true }

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

local function fromList(list: { read [number]: Rule }): (lunette.Window) -> Properties?
  return function(window: lunette.Window): Properties?
    local collected: Properties? = nil
    for index = 1, #list do
      local rule = list[index]
      if rule.properties and policy.matches(rule.match, window) then
        collected = layer(collected or {}, rule.properties)
      end
    end
    return collected
  end
end

local config = require '@lunette-plugins/rules/config'

export type Settings = config.Settings

local function build(context: plugin.Context, settings: Settings): Service
  local state: ProviderState = {
    context = context,
    sources = {},
    registrations = 0,
  }

  context:effect(function(): () -> ()
    return function()
      state.sources = {}
      state.registrations = 0
    end
  end)

  local service: Service
  service = {
    inspect = function(_self: Service): inspection.Snapshot
      local result: { inspection.Registration } = {}
      for _, entry in ipairs(orderedSources(state)) do
        result[#result + 1] = inspection.registration(
          'ruleSource',
          'rules.addSource',
          entry.owner,
          entry.name,
          context:owns(entry.owner),
          { precedence = entry.precedence, sequence = entry.sequence }
        )
      end
      return inspection.snapshot(result, nil, { 'resolved properties and matches require callbacks' })
    end,
    addSource = function(_self: Service, owner: Owner, registration: contracts.SourceRegistration): plugin.Effect
      context:checkOwner(owner)
      if type(registration) ~= 'table' then
        error('rules: a source registration is a table of fields, not a ' .. type(registration), 2)
      end
      plugin.rejectUnknownFields('rules addSource', registration, SOURCE_KEYS, 'name, precedence, and resolve', 2)
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

      -- A duplicate name cannot replace a source held by another owner.
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
          owner = owner,
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
    end,
    setRules = function(_self: Service, owner: Owner, set: contracts.RuleSet): plugin.Effect
      if type(set) ~= 'table' then
        error('rules: a rule set is a table of fields, not a ' .. type(set), 2)
      end
      plugin.rejectUnknownFields('rules setRules', set, RULE_SET_KEYS, 'name, precedence, and rules', 2)
      policy.checkRules(set.rules)
      return service:addSource(owner, {
        name = set.name or 'lunette.rules',
        precedence = set.precedence or settings.precedence,
        resolve = fromList(set.rules),
      })
    end,
    resolve = function(_self: Service, window: lunette.Window): Resolved
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
    end,
  }
  return service
end

return build
