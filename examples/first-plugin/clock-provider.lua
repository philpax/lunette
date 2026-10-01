-- A provider of the clock contract. The table given to `publish:provide` is
-- the service; consumers receive a view of it that stops working once this
-- plugin unloads.

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
