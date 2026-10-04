-- The plugin context releases the native event subscription when the activation ends.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local frame = require '@lunette-contracts/frame'
local clock = require './clock'

export type Config = { read prefix: string? }

return plugin.define {
  name = 'uptime',
  requires = { frame = frame.capability, clock = clock.capability },
  init = function(context: plugin.Context, config: Config, _publish: plugin.Publisher)
    local settings = plugin.options { name = 'uptime', defaults = { prefix = 'up' }, config = config }
    local frames: frame.Service = context:require(frame.capability)
    local time: clock.Service = context:require(clock.capability)
    local opened = 0
    context:on {
      event = lunette.onWindowOpened,
      run = function(_event: lunette.WindowOpenedEvent)
        opened += 1
      end,
    }
    local pose = lovr.math.newMat4():translate(0, 1.4, -1.5):scale(0.05)
    frames:onDraw(context, {
      phase = 'overlay',
      run = function(pass: Pass)
        pass:text(string.format('%s %.0fs, %d windows', settings.prefix, time:elapsed(), opened), pose)
      end,
    })
  end,
}
