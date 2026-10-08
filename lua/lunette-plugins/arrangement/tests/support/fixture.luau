-- Provides real persistence services over the fake native API.
local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local panelsContract = require '@lunette-contracts/panels'
local placementContract = require '@lunette-contracts/placement'
local rulesContract = require '@lunette-contracts/rules'
local tagsContract = require '@lunette-contracts/tags'

local fixture = {}

-- Runs `body` with a table of the runtime, the provider instances by id, the consumer's instance as
-- `owner`, and its `context`, `panels`, `tags`, `rules`, and `placement`. With `options.placement` the
-- placement provider runs too. With `options.bind`, a persistence state, the consumer binds it in its
-- initializer as `binding` and then calls `options.extend`, when given, with its context and the binding.
-- The consumer's fields are replaced each time it activates again. The runtime is closed afterwards, and
-- every layer claim must have been released. The native API is a fresh fake, or `options.native`.
function fixture.run(options, body)
  local native = options.native or testing.native()
  local entries = { 'theme', 'panels', 'tags', 'rules' }
  local requires = {
    panels = panelsContract.capability,
    tags = tagsContract.capability,
    rules = rulesContract.capability,
  }
  if options.placement then
    entries[#entries + 1] = 'placement'
    requires.placement = placementContract.capability
  end
  local session = testing.start(entries)
  local env = { runtime = session.runtime, providers = session.instances }
  local ok, failure = pcall(function()
    env.owner = session:use(plugin.define {
      name = 'persist-test',
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
    })
    expect.truthy(env.context and env.context:active(), 'the initialized consumer')
    body(env)
  end)
  local closeOk, closeFailure = pcall(function()
    session:close()
    native.assertResourcesReleased()
  end)
  if not ok then
    error(failure, 0)
  end
  if not closeOk then
    error(closeFailure, 0)
  end
end

return fixture
