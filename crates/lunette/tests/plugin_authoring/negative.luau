local plugin = require '@lunette-plugin'
local contracts = require './contracts'

type Config = contracts.Config

local definition = plugin.define(
  contracts.config,
  { clock = contracts.clock },
  {},
  function(context: plugin.Context, config: Config, _publish: plugin.Publisher)
    local _wrongResult: string = context:require(contracts.clock):now() -- reject: string.
    local _wrongConfig: number = config.prefix -- reject: number.
    context:effect 'acquire' -- reject: () -> () -> ().
    context:checkOwner 'not an owner' -- reject: Owner.
    context:provide(contracts.clock, {}) -- reject: provide.
    context:services() -- reject: unreachable.
  end
)

local runtime = plugin.runtime()
runtime:use(definition, { prefix = 42 }) -- reject: string.
local instance: plugin.Instance<Config> = runtime:use(definition, { prefix = 'valid' })
instance:reload { prefix = 42 } -- reject: string.

local child = plugin.define(function(value: contracts.ChildConfig): contracts.ChildConfig
  return value
end, {}, {}, function() end)
local function createChild(context: plugin.Context)
  context:child(child, { enabled = 'yes' }) -- reject: boolean.
end
return { instance = instance, createChild = createChild }
