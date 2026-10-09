local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local adapter = require '@lunette-plugin/adapter'
local contracts = require './contracts'

type Config = contracts.Config
type Service = { read count: (Service) -> number }

local definition = adapter.define {
  name = 'negative',
  requires = { contracts.clock },
  init = function(context: plugin.Context, config: Config, _publish: adapter.Publisher)
    local _wrongResult: string = context:require(contracts.clock):now() -- reject: string.
    local _wrongConfig: number = config.prefix -- reject: number.
    context:effect 'acquire' -- reject: () -> () -> ().
    context:checkOwner 'not an owner' -- reject: Owner.
    context:provide(contracts.clock, {}) -- reject: provide.
    context:services() -- reject: services.
  end,
}

local runtime = adapter.runtime()
runtime:use(definition, { prefix = 42 }) -- reject: string.
local instance: adapter.Instance<Config> = runtime:use(definition, { prefix = 'valid' })
instance:requestReload { prefix = 42 } -- reject: string.

local child = plugin.consumer<<contracts.ChildConfig, contracts.ChildConfig>> {
  name = 'child',
  init = function(_context: plugin.Context, _settings: contracts.ChildConfig) end,
}
local function createChild(context: plugin.Context, owner: plugin.Owner)
  context:child(child.definition, { enabled = 'yes' }) -- reject: ChildConfig?.
  owner:effect(function() -- reject: effect.
    return function() end
  end)
end

local notCapability: plugin.Declaration = { 'clock' } -- reject: string.
local keyed: plugin.Declaration = { clock = contracts.clock } -- reject: number.
local wrongWitness: plugin.Declaration = { { witness = 42 } } -- reject: number.

local native = lunette.plugin.runtime()
local token = lunette.plugin.contract('fixture/opaque', 1)
native:use({}, {}) -- reject: PluginDefinition.
native:use(token, {}) -- reject: PluginDefinition.

local named = plugin.capability<<Service>> { name = 'fixture/named', version = 1 }
local unnamed = plugin.capability { name = 'fixture/unnamed', version = 1 } -- reject: service type is unknown.

return {
  instance = instance,
  createChild = createChild,
  declarations = { notCapability, keyed, wrongWitness },
  token = token,
  named = named,
  unnamed = unnamed,
}
