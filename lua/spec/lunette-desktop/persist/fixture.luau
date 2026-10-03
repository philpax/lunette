-- The plugin runtime the persistence specs drive a state through: the real panels, tags, and rules
-- providers, and placement when asked for, with a consumer of them. Native layer claims are the one
-- unmanaged boundary, and each claim is answered by a stub.
local expect = require '@spec/expect'
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local panelsContract = require '@lunette-contracts/panels'
local placementContract = require '@lunette-contracts/placement'
local rulesContract = require '@lunette-contracts/rules'
local tagsContract = require '@lunette-contracts/tags'

local fixture = {}

-- Runs `body` with a table of the runtime, the provider instances by name, the consumer's instance as
-- `owner`, and its `context`, `panels`, `tags`, `rules`, and `placement`. With `options.placement` the
-- placement provider runs too. With `options.bind`, a persistence state, the consumer binds it in its
-- initializer as `binding` and then calls `options.extend`, when given, with its context and the binding.
-- The consumer's fields are replaced each time it activates again. The runtime is closed afterwards.
function fixture.run(options, body)
  local previousClaimLayer = lunette.claimLayer
  lunette.claimLayer = function(claimed)
    local claim = { dead = false, granted = false, layer = false, width = claimed.width, height = claimed.height }
    function claim:release()
      if self.dead then
        return false
      end
      self.dead = true
      return true
    end
    return claim
  end

  local runtime
  local ok, failure = pcall(function()
    runtime = plugin.runtime()
    local env = { runtime = runtime, providers = {} }
    local names = { 'panels', 'tags', 'rules' }
    local requires = {
      panels = panelsContract.capability,
      tags = tagsContract.capability,
      rules = rulesContract.capability,
    }
    if options.placement then
      names[#names + 1] = 'placement'
      requires.placement = placementContract.capability
    end
    for _, name in ipairs(names) do
      local instance = runtime:use(require('@lunette-plugins/' .. name).definition, {})
      instance:enable()
      env.providers[name] = instance
    end
    env.owner = runtime:use(
      plugin.define {
        name = 'persist-spec',
        requires = requires,
        init = function(current)
          env.context = current
          env.panels = current:require(panelsContract.capability)
          env.tags = current:require(tagsContract.capability)
          env.rules = current:require(rulesContract.capability)
          if options.placement then
            env.placement = current:require(placementContract.capability)
          end
          if options.bind then
            env.binding = options.bind:bind(current, env.panels, env.tags, env.rules)
            if options.extend then
              options.extend(current, env.binding)
            end
          end
        end,
      },
      {}
    )
    env.owner:enable()
    expect.truthy(env.context and env.context:active(), 'the initialized consumer')
    body(env)
  end)
  local closeOk, closeFailure = true, nil
  if runtime then
    closeOk, closeFailure = pcall(function()
      runtime:close()
    end)
  end
  lunette.claimLayer = previousClaimLayer
  if not ok then
    error(failure)
  end
  if not closeOk then
    error(closeFailure)
  end
end

return fixture
