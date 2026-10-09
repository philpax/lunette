local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local contracts = require './contracts'

type Config = contracts.Config
type Service = { read count: (Service) -> number }

local definition = plugin.define {
  name = 'negative',
  requires = { clock = contracts.clock },
  init = function(context: plugin.Context, config: Config, _publish: plugin.Publisher)
    local _wrongResult: string = context:require(contracts.clock):now() -- reject: string.
    local _wrongConfig: number = config.prefix -- reject: number.
    context:effect 'acquire' -- reject: () -> () -> ().
    context:checkOwner 'not an owner' -- reject: Owner.
    context:provide(contracts.clock, {}) -- reject: provide.
    context:services() -- reject: unreachable.
  end,
}

local runtime = plugin.runtime()
runtime:use(definition, { prefix = 42 }) -- reject: string.
local instance: plugin.Instance<Config> = runtime:use(definition, { prefix = 'valid' })
instance:reload { prefix = 42 } -- reject: string.

local child = plugin.define {
  name = 'child',
  init = function(_context: plugin.Context, _config: contracts.ChildConfig) end,
}
local function createChild(context: plugin.Context)
  context:child(child, { enabled = 'yes' }) -- reject: boolean.
end

local notCapability: plugin.Declaration = { clock = 'clock' } -- reject: string.
local nested: plugin.Declaration = { group = { clock = contracts.clock } } -- reject: witness.
local wrongWitness: plugin.Declaration = { clock = { witness = 42 } } -- reject: number.

local native = lunette.plugin.runtime()
local token = lunette.plugin.contract('fixture/opaque', 1)
native:use({}, {}) -- reject: PluginDefinition.
native:use(token, {}) -- reject: PluginDefinition.

local named = plugin.capability<<Service>> { name = 'fixture/named', schema = 1 }
local unnamed = plugin.capability { name = 'fixture/unnamed', schema = 1 } -- reject: service type is unknown.

return {
  instance = instance,
  createChild = createChild,
  declarations = { notCapability, nested, wrongWitness },
  token = token,
  named = named,
  unnamed = unnamed,
}
