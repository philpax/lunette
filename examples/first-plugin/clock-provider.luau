-- Consumers cannot use the published service after the provider activation ends.

local plugin = require '@lunette-plugin'
local clock = require './clock'

return plugin.define {
  name = 'clock',
  provides = { clock = clock.capability },
  init = function(_context: plugin.Context, _config: {}, publish: plugin.Publisher)
    local started = lovr.timer.getTime()
    publish:provide(clock.capability, {
      now = function(_self: clock.Service): number
        return lovr.timer.getTime()
      end,
      elapsed = function(_self: clock.Service): number
        return lovr.timer.getTime() - started
      end,
    })
  end,
}
