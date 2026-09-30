local plugin = require '@lunette-plugin'
local contracts = require './contracts'

type Config = contracts.Config
type ChildConfig = contracts.ChildConfig

local function identity(value: Config): Config
  return value
end

local child = plugin.define(function(value: ChildConfig): ChildConfig
  return value
end, {}, {}, function(context: plugin.Context, config: ChildConfig, _publish: plugin.Publisher)
  assert(config.enabled)
  context:effect(function(): () -> ()
    return function() end
  end)
end)

local definition = plugin.define(
  identity,
  { clock = contracts.clock },
  {},
  function(context: plugin.Context, config: Config, _publish: plugin.Publisher)
    local service: contracts.Clock = context:require(contracts.clock)
    context:effect(function(): () -> ()
      service:now()
      assert(#config.prefix > 0)
      return function() end
    end)
    local childInstance: plugin.Instance<ChildConfig> = context:child(child, { enabled = true })
    childInstance:enable()
    childInstance:reload { enabled = false }
  end
)

local runtime = plugin.runtime()
local instance: plugin.Instance<Config> = runtime:use(definition, { prefix = 'fixture' })
instance:enable()
instance:disable()
instance:reload { prefix = 'reload' }
instance:dispose()
runtime:drain()
runtime:close()

local function useOwner(context: plugin.Context, caller: plugin.Owner)
  context:checkOwner(caller)
  caller:effect(function()
    return function() end
  end)
end

return { definition = definition, instance = instance, useOwner = useOwner }
