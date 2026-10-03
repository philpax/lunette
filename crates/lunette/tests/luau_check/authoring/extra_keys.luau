local plugin = require '@lunette-plugin'
local contracts = require './contracts'

local capabilities: plugin.Declaration = { clock = contracts.clock, log = contracts.log }
capabilities.clock = contracts.clock

local definition = plugin.define {
  name = 'extra-keys',
  provides = capabilities,
  init = function(_context: plugin.Context, _config: contracts.Config, publish: plugin.Publisher)
    publish:provide(contracts.clock, {
      now = function(_self: contracts.Clock): number
        return 1
      end,
      extra = true,
    })
    publish:provide(contracts.log, {
      write = function(_self: contracts.Log, _message: string) end,
    })
  end,
}
return definition
