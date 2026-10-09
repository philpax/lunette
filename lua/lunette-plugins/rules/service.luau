-- Rule sources are activation-scoped and ordered. Placement policy is applied by lunette/placement.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local contracts = require '@lunette-contracts/rules'
local policy = require '@lunette-plugins/rules/policy'
local inspection = require '@lunette-contracts/inspection'
local config = require '@lunette-plugins/rules/config'

export type Service = contracts.Service
export type Owner = contracts.Owner
export type Properties = contracts.Properties
export type Resolved = contracts.Resolved
export type Rule = contracts.Rule
export type Settings = config.Settings

type Source = {
  name: string,
  precedence: number,
  owner: Owner,
  resolve: (lunette.Window) -> Properties?,
  sequence: number,
}

local SOURCE_KEYS: { string } = { 'name', 'precedence', 'resolve' }
local RULE_SET_KEYS: { string } = { 'name', 'precedence', 'rules' }

local function fromList(list: { read [number]: Rule }): (lunette.Window) -> Properties?
  return function(window: lunette.Window): Properties?
    local collected: Properties? = nil
    for index = 1, #list do
      local rule = list[index]
      if rule.properties and policy.matches(rule.match, window) then
        collected = policy.layer(collected or {}, rule.properties)
      end
    end
    return collected
  end
end

local function build(context: plugin.Context, settings: Settings): Service
  -- Sources stay ordered by precedence, then by registration.
  local sources: { Source } = {}
  local registrations = 0

  local service: Service
  service = {
    inspect = function(_self: Service): inspection.Snapshot
      local result: { inspection.Registration } = {}
      for _, entry in ipairs(sources) do
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
      plugin.rejectUnknownFields('rules addSource', registration, SOURCE_KEYS, 2)
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
      for _, previous in ipairs(sources) do
        if previous.name == name then
          error("rules: a source named '" .. name .. "' is already registered", 2)
        end
      end
      return context:acquire(owner, function(): () -> ()
        registrations += 1
        local source: Source = {
          owner = owner,
          name = name,
          precedence = precedence,
          resolve = resolve,
          sequence = registrations,
        }
        local position = #sources + 1
        while position > 1 and sources[position - 1].precedence > precedence do
          position -= 1
        end
        table.insert(sources, position, source)
        return function(): ()
          local index = table.find(sources, source)
          if index then
            table.remove(sources, index)
          end
        end
      end)
    end,
    setRules = function(_self: Service, owner: Owner, set: contracts.RuleSet): plugin.Effect
      plugin.rejectUnknownFields('rules setRules', set, RULE_SET_KEYS, 2)
      policy.checkRules(set.rules)
      return service:addSource(owner, {
        name = set.name or 'lunette.rules',
        precedence = set.precedence or settings.precedence,
        resolve = fromList(set.rules),
      })
    end,
    resolve = function(_self: Service, window: lunette.Window): Resolved
      local collected: Properties = {}
      -- A resolver can add or remove sources, so the walk uses a snapshot.
      for _, source in ipairs(table.clone(sources)) do
        local answered = source.resolve(window)
        if answered ~= nil then
          if type(answered) ~= 'table' then
            error("rules: the source '" .. source.name .. "' answered a " .. type(answered) .. ', not a table')
          end
          policy.layer(collected, policy.checkProperties(answered))
        end
      end
      return policy.evaluate(collected, window)
    end,
  }
  return service
end

return build
