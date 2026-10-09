local plugin = require '@lunette-plugin'
local adapter = require '@lunette-plugin/adapter'
local contracts = require './contracts'

type Config = contracts.Config
type ChildConfig = contracts.ChildConfig

local child = plugin.consumer<<ChildConfig, ChildConfig>> {
  name = 'child',
  init = function(context: plugin.Context, settings: ChildConfig)
    assert(settings.enabled)
    context:effect(function(): () -> ()
      return function() end
    end)
  end,
}

local definition = plugin.consumer<<Config, Config>> {
  name = 'positive',
  requires = { contracts.clock },
  init = function(context: plugin.Context, settings: Config)
    local service: contracts.Clock = context:require(contracts.clock)
    context:effect(function(): () -> ()
      service:now()
      assert(#settings.prefix > 0)
      return function() end
    end)
    context:child(child.definition, { enabled = true })
    context:child(child.definition)
  end,
}

local runtime = adapter.runtime()
local instance: adapter.Instance<Config> = runtime:use(definition.definition, { prefix = 'fixture' })
instance:enable()
instance:disable()
instance:requestReload { prefix = 'reload' }
instance:dispose()
runtime:drain()
runtime:close()

local function useOwner(context: plugin.Context, caller: plugin.Owner)
  context:checkOwner(caller)
  context:acquire(caller, function()
    return function() end
  end)
  local _value: number = context:resource(caller, function(): (number, () -> ())
    return 1, function() end
  end)
end

return { definition = definition, instance = instance, useOwner = useOwner }
